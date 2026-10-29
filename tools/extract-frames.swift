import AppKit
import AVFoundation

let source = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
let asset = AVURLAsset(url: URL(fileURLWithPath: source))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let duration = CMTimeGetSeconds(asset.duration)
print("Duration: \(duration)s; tracks: \(asset.tracks(withMediaType: .video).map { $0.naturalSize })")
let interval = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 3.0
for second in stride(from: 0.0, to: duration, by: interval) {
    do {
        let cg = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil)
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let data = bitmap.representation(using: .png, properties: [:])!
        let name = String(format: "frame-%05.1f.png", second)
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
        print(name)
    } catch { print(error) }
}
