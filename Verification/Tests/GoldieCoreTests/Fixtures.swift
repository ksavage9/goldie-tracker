import UIKit
@testable import GoldieCore

/// Synthetic Find My screenshots: a map with roads and a park, a sidebar with Goldie's icon in it,
/// and (optionally) her marker on the map.
enum Fixtures {
    static let size = CGSize(width: 1366, height: 1024)  // iPad's 4:3 shape, smaller so tests run fast
    static let sidebarIcon = CGPoint(x: 50, y: 120)

    static func screenshot(marker: CGPoint?, face: UIColor = .orange, size: CGSize = size) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor(white: 0.92, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            for x in stride(from: 380.0, to: size.width, by: 140) {
                context.fill(CGRect(x: x, y: 0, width: 10, height: size.height))
            }
            for y in stride(from: 60.0, to: size.height, by: 120) {
                context.fill(CGRect(x: 360, y: y, width: size.width - 360, height: 10))
            }
            UIColor(red: 0.75, green: 0.88, blue: 0.70, alpha: 1).setFill()
            context.fill(CGRect(x: 700, y: 400, width: 250, height: 200))
            UIColor(white: 0.97, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: size.height))
            drawMarker(at: sidebarIcon, face: face, in: cg)
            if let marker {
                drawMarker(at: marker, face: face, in: cg)
            }
        }
    }

    /// White ring, colored face, two dark eyes: roughly an emoji marker on the Find My map.
    static func drawMarker(at c: CGPoint, face: UIColor, in cg: CGContext) {
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillEllipse(in: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))
        cg.setFillColor(face.cgColor)
        cg.fillEllipse(in: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30))
        cg.setFillColor(UIColor.black.cgColor)
        cg.fillEllipse(in: CGRect(x: c.x - 7, y: c.y - 8, width: 5, height: 5))
        cg.fillEllipse(in: CGRect(x: c.x + 2, y: c.y - 8, width: 5, height: 5))
    }

    /// Saves a screenshot the way the shortcut does (JPEG, about 50%) with the given creation date.
    @discardableResult
    static func write(_ image: UIImage, to url: URL, created: Date) throws -> Screenshot {
        let data = image.jpegData(compressionQuality: 0.5)!
        try data.write(to: url)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
        return Screenshot(url: url, date: created, bytes: Int64(data.count))
    }

    static func makeTemporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Average brightness (0...1) of an area, with y measured from the top. Letters and background mix,
    /// so this tells a dark pill from the light map even where text is drawn.
    static func averageBrightness(of image: CGImage, x: Int, y: Int, width: Int, height: Int) -> Double {
        let area = image.cropping(to: CGRect(x: x, y: y, width: width, height: height))!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(area, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / (3 * 255)
        }
        return total / Double(width * height)
    }

    /// Brightness (0...1) of one pixel, with y measured from the top.
    static func brightness(of image: CGImage, x: Int, y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}
