import AVFoundation
import UIKit

/// Turns a day's screenshots into an MP4, one screenshot per frame, each stamped with its time.
enum VideoBuilder {
    static let framesPerSecond: Int32 = 5
    static let maxWidth: CGFloat = 1280

    static func makeVideo(
        from screenshots: [Screenshot],
        to outputURL: URL,
        showsDate: Bool = false,  // for animations that span days
        onProgress: @MainActor (Double) -> Void
    ) async throws {
        // The first screenshot that opens sets the video size.
        guard let firstImage = screenshots.lazy.compactMap({ UIImage(contentsOfFile: $0.url.path) }).first else {
            throw BuildError("No readable screenshots for this day.")
        }
        let size = videoSize(for: firstImage.size)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? BuildError("The video could not be started.")
        }
        writer.startSession(atSourceTime: .zero)

        // The writer fails if the app goes to the background mid-build (iOS stops video encoding there).
        // After that it never becomes ready again and calling it further raises an exception, so every
        // step checks it's still writing.
        func stopped() -> Error {
            writer.error ?? BuildError("The video could not be written.")
        }
        do {
            var frameIndex: Int64 = 0
            for (index, screenshot) in screenshots.enumerated() {
                try Task.checkCancellation()  // stop if the screen that started it was closed
                guard writer.status == .writing else { throw stopped() }
                await onProgress(Double(index) / Double(screenshots.count))
                let frame = autoreleasepool {
                    makeFrame(screenshot, size: size, showsDate: showsDate, pool: adaptor.pixelBufferPool)
                }
                guard let frame else { continue }  // unreadable file, skip it

                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw stopped() }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard adaptor.append(frame, withPresentationTime: CMTime(value: frameIndex, timescale: framesPerSecond)) else {
                    throw stopped()
                }
                frameIndex += 1
            }
            guard frameIndex > 0 else { throw BuildError("No readable screenshots for this day.") }
            guard writer.status == .writing else { throw stopped() }

            // End one frame after the last one so the final screenshot is shown for its full duration.
            writer.endSession(atSourceTime: CMTime(value: frameIndex, timescale: framesPerSecond))
            input.markAsFinished()
        } catch {
            if writer.status == .writing {
                writer.cancelWriting()  // stop encoding and let go of the file
            }
            throw error
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? BuildError("The video could not be finished.")
        }
    }

    private static func videoSize(for imageSize: CGSize) -> CGSize {
        let scale = min(1, maxWidth / imageSize.width)
        // H.264 needs even dimensions.
        let width = Int(imageSize.width * scale) / 2 * 2
        let height = Int(imageSize.height * scale) / 2 * 2
        return CGSize(width: width, height: height)
    }

    static func makeFrame(_ screenshot: Screenshot, size: CGSize, showsDate: Bool, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        // Decoded straight at the video's size, which is much faster than decoding the full screenshot.
        guard let pool, let image = ImageFile.downsampled(screenshot.url, maxPixelSize: Int(max(size.width, size.height))) else {
            return nil
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }

        // Drawn straight into the video frame, with no in-between image.
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let frame = CGRect(origin: .zero, size: size)
        context.setFillColor(UIColor.black.cgColor)
        context.fill(frame)
        context.draw(image, in: AVMakeRect(aspectRatio: CGSize(width: image.width, height: image.height), insideRect: frame))
        // The time stamp is drawn the UIKit way, top-down, so flip the context first.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        drawTimestamp(screenshot.date, showsDate: showsDate, in: size)
        UIGraphicsPopContext()
        return buffer
    }

    /// Draws the screenshot's time (e.g. "3:05 PM", or "Sep 29, 3:05 PM" with the date) in the bottom-right corner.
    private static func drawTimestamp(_ date: Date, showsDate: Bool, in size: CGSize) {
        let text = (showsDate ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) : date.timeText) as NSString
        let baseFont = UIFont.monospacedDigitSystemFont(ofSize: size.height * 0.028, weight: .semibold)
        let font = baseFont.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? baseFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = size.height * 0.0075
        let margin = padding * 2  // gap between the pill and the frame's edges
        let box = CGRect(
            x: size.width - textSize.width - padding * 2 - margin,
            y: size.height - textSize.height - padding * 2 - margin,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        UIColor.black.withAlphaComponent(0.6).setFill()
        UIBezierPath(roundedRect: box, cornerRadius: padding).fill()
        text.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding), withAttributes: attributes)
    }
}
