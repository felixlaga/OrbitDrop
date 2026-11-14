// Off-screen video conversion tests. The clips are made here with AVFoundation, so the repo
// carries no video fixtures. No windows, no network, no third-party tools.
import AVFoundation
import Foundation
import ImageIO

@main
struct VideoEngineTests {
    struct TestFailure: Error, CustomStringConvertible { let description: String }
    static var assertions = 0
    static func check(_ condition: Bool, _ message: String) throws {
        assertions += 1
        if !condition { throw TestFailure(description: message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { assertions += 1; return }
        throw TestFailure(description: "Expected an error: \(message)")
    }

    static func main() {
        do { try runTests() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    // MARK: Fixtures

    /// A silent clip of grey frames that change shade every frame.
    static func writeVideo(_ url: URL, seconds: Int, fps: Int32, codec: AVVideoCodecType, width: Int = 320, height: Int = 180) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw TestFailure(description: "Video writer: \(writer.error?.localizedDescription ?? "unknown")") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw TestFailure(description: "No pixel buffer pool") }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard let pixels = created else { throw TestFailure(description: "No pixel buffer") }
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels)!, Int32(40 + (frame * 7) % 200), CVPixelBufferGetBytesPerRow(pixels) * height)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                throw TestFailure(description: "Frame \(frame): \(writer.error?.localizedDescription ?? "append failed")")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw TestFailure(description: "Video writer: \(writer.error?.localizedDescription ?? "did not finish")") }
    }

    /// A 440 Hz tone as AAC.
    static func writeTone(_ url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { samples[i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    } // The file closes here.

    /// Puts the tone under the clip, giving an H.264 + AAC MOV like a screen recording with sound.
    static func mux(video: URL, audio: URL, into output: URL) throws {
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        let duration = try VideoEngine.blocking { try await videoAsset.load(.duration) }
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let sourceVideo = try VideoEngine.blocking({ try await videoAsset.loadTracks(withMediaType: .video) }).first,
              let sourceAudio = try VideoEngine.blocking({ try await audioAsset.loadTracks(withMediaType: .audio) }).first else {
            throw TestFailure(description: "Fixture tracks missing")
        }
        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: sourceVideo, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: sourceAudio, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw TestFailure(description: "No passthrough export for the fixture")
        }
        session.outputURL = output; session.outputFileType = .mov
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        guard session.status == .completed else { throw TestFailure(description: "Fixture mux: \(session.error?.localizedDescription ?? "failed")") }
    }

    // MARK: Independent readers

    static func tracks(_ url: URL, _ type: AVMediaType) throws -> [AVAssetTrack] {
        let asset = AVURLAsset(url: url)
        return try VideoEngine.blocking { try await asset.loadTracks(withMediaType: type) }
    }
    static func codec(_ url: URL, _ type: AVMediaType) throws -> FourCharCode? {
        guard let track = try tracks(url, type).first else { return nil }
        return try VideoEngine.blocking { try await track.load(.formatDescriptions) }.first.map { CMFormatDescriptionGetMediaSubType($0) }
    }
    static func seconds(_ url: URL) throws -> Double {
        let asset = AVURLAsset(url: url)
        return try VideoEngine.blocking { try await asset.load(.duration) }.seconds
    }
    static func gifInfo(_ url: URL) throws -> (frames: Int, width: Int, height: Int) {
        let data = try Data(contentsOf: url)
        let header = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        try check(data.starts(with: Data("GIF89a".utf8)) || data.starts(with: Data("GIF87a".utf8)),
                  "\(url.lastPathComponent) is not a GIF: \(data.count) bytes, header \(header)")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw TestFailure(description: "ImageIO could not read \(url.lastPathComponent)")
        }
        return (CGImageSourceGetCount(source), width, height)
    }
    static func leftovers(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".orbitdrop") }
    }

    // MARK: Tests

    static func runTests() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("OrbitDrop-video-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        print("OFFSCREEN video artifacts: \(directory.path)")

        let silent = directory.appendingPathComponent("Silent clip.mov")
        try writeVideo(silent, seconds: 2, fps: 10, codec: .h264)
        let tone = directory.appendingPathComponent("tone.m4a")
        try writeTone(tone, seconds: 3)
        let clip = directory.appendingPathComponent("Clip 日本.mov")
        try mux(video: silent, audio: tone, into: clip)
        try check(try codec(clip, .video) == kCMVideoCodecType_H264 && codec(clip, .audio) == kAudioFormatMPEG4AAC, "Fixture is H.264 + AAC")
        let original = try Data(contentsOf: clip)
        // verify-package.py converts this same clip with the packaged app.
        let shared = URL(fileURLWithPath: "build/tests/Sample-video.mov")
        try? fm.removeItem(at: shared)
        try? fm.copyItem(at: clip, to: shared)

        // Recognition.
        try check(VideoEngine.isVideo(clip) && VideoEngine.isVideo(URL(fileURLWithPath: "/x/a.MP4"))
                  && VideoEngine.isVideo(URL(fileURLWithPath: "/x/a.m4v")) && !VideoEngine.isVideo(URL(fileURLWithPath: "/x/a.png")),
                  "Video extensions")

        // MP4 from H.264 + AAC copies the tracks, next to the original.
        var reported: [Double] = []
        let mp4 = try MediaEngine.convert(clip, to: "mp4", progress: { reported.append($0) })
        try check(mp4.map(\.lastPathComponent) == ["Clip 日本.mp4"], "MP4 name: \(mp4)")
        let mp4Data = try Data(contentsOf: mp4[0])
        try check(mp4Data.count > 12 && String(data: mp4Data[4..<8], encoding: .ascii) == "ftyp", "MP4 container")
        try check(try codec(mp4[0], .video) == kCMVideoCodecType_H264, "MP4 video is H.264")
        try check(try codec(mp4[0], .audio) == kAudioFormatMPEG4AAC, "MP4 keeps the AAC sound")
        try check(abs(try seconds(mp4[0]) - 2) < 0.2, "MP4 keeps the length")
        try check(reported.last == 1, "Progress ends at 1: \(reported)")

        // MOV next to the original never overwrites it.
        let mov = try MediaEngine.convert(clip, to: ".MOV")
        try check(mov.map(\.lastPathComponent) == ["Clip 日本 2.mov"], "MOV name: \(mov)")
        try check(try tracks(mov[0], .video).count == 1 && tracks(mov[0], .audio).count == 1, "MOV keeps picture and sound")

        // GIF: 10 frames a second, original size when it is small.
        let gif = try MediaEngine.convert(clip, to: "gif")
        try check(gif.map(\.lastPathComponent) == ["Clip 日本.gif"], "GIF name: \(gif)")
        let small = try gifInfo(gif[0])
        try check(abs(small.frames - 20) <= 1, "2 s at 10 fps gives about 20 frames, got \(small.frames)")
        try check(small.width == 320 && small.height == 180, "A small clip keeps its size: \(small)")

        // M4A keeps only the sound.
        let m4a = try MediaEngine.convert(clip, to: "m4a")
        try check(m4a.map(\.lastPathComponent) == ["Clip 日本.m4a"], "M4A name: \(m4a)")
        try check(try tracks(m4a[0], .audio).count == 1 && tracks(m4a[0], .video).isEmpty, "M4A is sound only")
        try check(try codec(m4a[0], .audio) == kAudioFormatMPEG4AAC, "M4A is AAC")

        // A clip with no sound can't become M4A, and leaves nothing behind.
        try rejects("silent clip to M4A") { _ = try MediaEngine.convert(silent, to: "m4a") }
        try check(!fm.fileExists(atPath: directory.appendingPathComponent("Silent clip.m4a").path), "No M4A for a silent clip")

        // ProRes can't be copied into MP4, so it is re-encoded to H.264. Big clips make smaller GIFs.
        let master = directory.appendingPathComponent("Master.mov")
        try writeVideo(master, seconds: 1, fps: 10, codec: .proRes422, width: 1280, height: 720)
        try check(try codec(master, .video) == kCMVideoCodecType_AppleProRes422, "Fixture is ProRes")
        let encoded = try MediaEngine.convert(master, to: "mp4")
        try check(try codec(encoded[0], .video) == kCMVideoCodecType_H264, "ProRes becomes H.264 in MP4")
        let large = try gifInfo(try MediaEngine.convert(master, to: "gif")[0])
        try check(large.width == 640 && large.height == 360, "GIFs are at most 640 px wide: \(large)")
        try check(abs(large.frames - 10) <= 1, "1 s gives about 10 frames, got \(large.frames)")

        // GIFs stop at 30 seconds.
        let long = directory.appendingPathComponent("Long.mov")
        try writeVideo(long, seconds: 32, fps: 1, codec: .h264)
        try rejects("32 s clip to GIF") { _ = try MediaEngine.convert(long, to: "gif") }
        try check(!fm.fileExists(atPath: directory.appendingPathComponent("Long.gif").path), "No GIF for a long clip")

        // Cancelling saves nothing: before an export starts, and halfway through a GIF.
        do { _ = try MediaEngine.convert(clip, to: "mp4", isCancelled: { true }); throw TestFailure(description: "Cancelled MP4 was saved") }
        catch MediaEngine.Failure.cancelled { assertions += 1 }
        var polls = 0
        do {
            _ = try MediaEngine.convert(clip, to: "gif", isCancelled: { polls += 1; return polls > 5 })
            throw TestFailure(description: "Cancelled GIF was saved")
        } catch MediaEngine.Failure.cancelled { assertions += 1 }
        try check(!fm.fileExists(atPath: directory.appendingPathComponent("Clip 日本 2.gif").path), "Cancelled GIF left a file")
        try check(!fm.fileExists(atPath: directory.appendingPathComponent("Clip 日本 2.mp4").path), "Cancelled MP4 left a file")

        // Wrong pairs are refused before any work.
        try rejects("video to WEBM") { _ = try MediaEngine.convert(clip, to: "webm") }
        try rejects("video to PNG") { _ = try MediaEngine.convert(clip, to: "png") }
        try rejects("image to MP4") { _ = try MediaEngine.convert(URL(fileURLWithPath: "Tests/Fixtures/Sample.png"), to: "mp4") }

        let left = try leftovers(directory)
        try check(left.isEmpty, "Staging folders left behind: \(left)")
        try check(try Data(contentsOf: clip) == original, "The original clip is unchanged")
        print("PASS: \(assertions) video assertions: MP4 copy and re-encode, MOV, GIF size, frame rate and 30 s cap, M4A, silent clip, cancel, refusals, no leftovers, original untouched.")
    }
}
