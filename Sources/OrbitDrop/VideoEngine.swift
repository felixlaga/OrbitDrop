import AVFoundation
import CoreMedia
import ImageIO

/// Video conversion with Apple's own AVFoundation, so the app bundles no video codec.
/// Reads MOV, MP4 and M4V. Writes MP4 (H.264), MOV, GIF and M4A (sound only).
/// Synchronous: call from a worker queue. `MediaEngine.convert` stages and publishes the result.
enum VideoEngine {
    static let inputExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let outputFormats = ["mp4", "mov", "gif", "m4a"]
    /// GIFs get large fast, so they are capped: 10 frames a second, 640 px on the longest side, 30 seconds.
    static let gifFramesPerSecond = 10.0
    static let gifLongestSide: CGFloat = 640
    static let gifMaximumSeconds = 30.0

    static func isVideo(_ url: URL) -> Bool { inputExtensions.contains(url.pathExtension.lowercased()) }

    static func normalized(_ format: String) throws -> String {
        var value = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix(".") { value.removeFirst() }
        guard outputFormats.contains(value) else {
            throw MediaEngine.Failure.unsupported("Videos convert to MP4, MOV, GIF or M4A, not \(format.uppercased()).")
        }
        return value
    }

    /// Writes `source` as `format` to `output`, which must not exist yet.
    /// `progress` gets 0...1 on the calling thread. `isCancelled` is polled while the work runs.
    static func export(_ source: URL, to format: String, output: URL,
                       progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        if isCancelled() { throw MediaEngine.Failure.cancelled }
        let asset = AVURLAsset(url: source)
        let (readable, exportable) = try blocking { try await asset.load(.isReadable, .isExportable) }
        guard readable else { throw MediaEngine.Failure.unreadable(source.lastPathComponent) }
        guard exportable else {
            throw MediaEngine.Failure.unsupported("\(source.lastPathComponent) is copy-protected, so it can't be converted.")
        }
        let video = try blocking { try await asset.loadTracks(withMediaType: .video) }
        let audio = try blocking { try await asset.loadTracks(withMediaType: .audio) }
        switch format {
        case "gif":
            guard !video.isEmpty else { throw MediaEngine.Failure.unsupported("This file has no picture to turn into a GIF.") }
            try writeGIF(asset, to: output, progress: progress, isCancelled: isCancelled)
        case "m4a":
            guard !audio.isEmpty else { throw MediaEngine.Failure.unsupported("This video has no sound to save as M4A.") }
            try exportSession(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, label: "M4A", to: output,
                              progress: progress, isCancelled: isCancelled)
        case "mov":
            // QuickTime holds every codec AVFoundation reads, so the tracks are copied as they are.
            try exportSession(asset, preset: AVAssetExportPresetPassthrough, type: .mov, label: "MOV", to: output,
                              progress: progress, isCancelled: isCancelled)
        case "mp4":
            // H.264 with AAC plays everywhere, so it is copied untouched. Anything else (HEVC, ProRes,
            // PCM sound) is re-encoded to H.264, the MP4 most players and websites accept.
            if try playsEverywhereAsMP4(video: video, audio: audio) {
                do {
                    try exportSession(asset, preset: AVAssetExportPresetPassthrough, type: .mp4, label: "MP4", to: output,
                                      progress: progress, isCancelled: isCancelled)
                    return
                } catch MediaEngine.Failure.cancelled {
                    throw MediaEngine.Failure.cancelled
                } catch {
                    try? FileManager.default.removeItem(at: output)
                }
            }
            try exportSession(asset, preset: AVAssetExportPresetHighestQuality, type: .mp4, label: "MP4", to: output,
                              progress: progress, isCancelled: isCancelled)
        default:
            throw MediaEngine.Failure.unsupported("Videos convert to MP4, MOV, GIF or M4A.")
        }
    }

    private static func playsEverywhereAsMP4(video: [AVAssetTrack], audio: [AVAssetTrack]) throws -> Bool {
        func codecs(_ tracks: [AVAssetTrack]) throws -> [FourCharCode] {
            try tracks.flatMap { track in
                try blocking { try await track.load(.formatDescriptions) }.map { CMFormatDescriptionGetMediaSubType($0) }
            }
        }
        let videoCodecs = try codecs(video), audioCodecs = try codecs(audio)
        return !videoCodecs.isEmpty
            && videoCodecs.allSatisfy { $0 == kCMVideoCodecType_H264 }
            && audioCodecs.allSatisfy { $0 == kAudioFormatMPEG4AAC }
    }

    private static func exportSession(_ asset: AVAsset, preset: String, type: AVFileType, label: String, to output: URL,
                                      progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        if isCancelled() { throw MediaEngine.Failure.cancelled }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaEngine.Failure.encoding("This video can't be saved as \(label).")
        }
        session.outputURL = output
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = type == .mp4
        let finished = DispatchSemaphore(value: 0)
        session.exportAsynchronously { finished.signal() }
        while finished.wait(timeout: .now() + 0.2) == .timedOut {
            if isCancelled() { session.cancelExport() }
            progress(Double(session.progress))
        }
        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw MediaEngine.Failure.cancelled
        default: throw MediaEngine.Failure.encoding(session.error?.localizedDescription ?? "The \(label) export failed.")
        }
    }

    private static func writeGIF(_ asset: AVAsset, to output: URL, progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        let seconds = try blocking { try await asset.load(.duration) }.seconds
        guard seconds.isFinite, seconds > 0 else { throw MediaEngine.Failure.unreadable("the video's length") }
        guard seconds <= gifMaximumSeconds + 0.05 else {
            throw MediaEngine.Failure.unsupported("GIFs work for clips up to \(Int(gifMaximumSeconds)) seconds. This video is \(Int(seconds.rounded())) seconds long, so trim it first.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: gifLongestSide, height: gifLongestSide)
        let tolerance = CMTime(seconds: 0.5 / gifFramesPerSecond, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let count = max(1, Int((seconds * gifFramesPerSecond).rounded(.down)))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, count, nil) else {
            throw MediaEngine.Failure.encoding("The system GIF encoder is unavailable.")
        }
        let loop: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0] as [CFString: Any]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let delay = 1 / gifFramesPerSecond
        let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                                      kCGImagePropertyGIFUnclampedDelayTime: delay] as [CFString: Any]]
        for index in 0..<count {
            if isCancelled() { throw MediaEngine.Failure.cancelled }
            let time = CMTime(seconds: Double(index) / gifFramesPerSecond, preferredTimescale: 600)
            let image = try blocking { try await generator.image(at: time).image }
            CGImageDestinationAddImage(destination, image, frame as CFDictionary)
            progress(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else { throw MediaEngine.Failure.encoding("GIF encoding failed.") }
        // ImageIO labels the file GIF87a, but the frame delays and looping need GIF89a, so fix the label.
        var bytes = data as Data
        if bytes.starts(with: Data("GIF87a".utf8)) { bytes.replaceSubrange(3..<6, with: Data("89a".utf8)) }
        try bytes.write(to: output, options: .withoutOverwriting)
    }

    private final class Outcome<T>: @unchecked Sendable { var result: Result<T, Error>? }

    /// Runs one of AVFoundation's async loads from synchronous code. Never call it from inside a Task.
    static func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { outcome.result = .success(try await operation()) } catch { outcome.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try outcome.result!.get()
    }
}
