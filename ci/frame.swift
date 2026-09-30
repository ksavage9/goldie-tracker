// Saves one frame of an animation as a PNG, so the time stamp can be checked by eye.
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let frame = try await generator.image(at: CMTime(value: 1, timescale: 10)).image
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, frame, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("couldn't save the frame") }
print("Saved a \(frame.width)×\(frame.height) frame")
