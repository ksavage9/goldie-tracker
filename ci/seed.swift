// Fills a Goldie folder with realistic, full-size Find My-style screenshots over three days
// (with real creation dates), then prints a bookmark to it for the app's settings.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let width = 2732, height = 2048  // a 12.9"/13" iPad Pro screenshot

func screenshot(marker: CGPoint) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(height))  // y from the top, like a screenshot
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(gray: 0.92, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 1, alpha: 1)
    for x in stride(from: 760, to: width, by: 280) { context.fill(CGRect(x: x, y: 0, width: 20, height: height)) }
    for y in stride(from: 120, to: height, by: 240) { context.fill(CGRect(x: 720, y: y, width: width - 720, height: 20)) }
    context.setFillColor(red: 0.75, green: 0.88, blue: 0.70, alpha: 1)
    context.fill(CGRect(x: 1400, y: 800, width: 500, height: 400))
    context.setFillColor(gray: 0.97, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 720, height: height))
    for center in [CGPoint(x: 100, y: 240), marker] {
        context.setFillColor(gray: 1, alpha: 1)
        context.fillEllipse(in: CGRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88))
        context.setFillColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)
        context.fillEllipse(in: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
    }
    return context.makeImage()!
}

let calendar = Calendar.current
let todayStart = calendar.startOfDay(for: .now)
for (daysAgo, count) in [(2, 12), (1, 12), (0, 6)] {
    let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: todayStart)!
    for i in 0..<count {
        var created = dayStart + 7 * 3600 + Double(i) * 300
        if daysAgo == 0 { created = max(dayStart + Double(i), min(created, Date.now - 60)) }  // never in the future
        let url = folder.appending(path: "Goldie \(daysAgo)-\(i).jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let marker = CGPoint(x: 1200 + Double(i) * 60, y: 600 + Double(daysAgo) * 300)
        CGImageDestinationAddImage(destination, screenshot(marker: marker), [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(url.path)") }
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
    }
}
print(try folder.bookmarkData().map { String(format: "%02x", $0) }.joined())
