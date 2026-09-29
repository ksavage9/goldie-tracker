import Accelerate
import UIKit

/// Goldie's map marker, cut out of one screenshot, used to find her in every other screenshot.
struct MarkerTemplate: Codable {
    struct Pixel: Codable {
        let dx: Int
        let dy: Int
        let value: Float
    }

    let pixels: [Pixel]  // grayscale disc around the marker's center
    let radius: Int
    let decoys: [GridPoint]  // other spots that look like the marker, e.g. her icon in the Find My list
}

struct GridPoint: Codable, Hashable {
    let x: Int
    let y: Int
}

struct Heatmap {
    let base: UIImage
    let overlay: UIImage
    let found: Int
    let total: Int
    let busiestSpot: CGPoint  // 0...1 within the image
    let busiestSpotMinutes: Int
}

/// Finds Goldie's marker in each of a day's screenshots and turns where she was into a heat map.
/// Screenshots are shrunk to a 640-pixel-wide grayscale grid first so matching stays fast.
enum HeatmapBuilder {
    static let gridWidth = 640
    static let matchThreshold: Float = 0.01  // mean squared brightness difference that still counts as "that's Goldie"
    static let minutesPerScreenshot = 5

    /// Heat colors from cool to hot, shared by the overlay and the legend.
    static let colorStops: [(position: Float, red: Float, green: Float, blue: Float, alpha: Float)] = [
        (0.00, 0.20, 0.35, 1.00, 0.00),
        (0.12, 0.20, 0.40, 1.00, 0.35),
        (0.35, 0.00, 0.85, 0.95, 0.55),
        (0.55, 0.45, 0.95, 0.30, 0.70),
        (0.75, 1.00, 0.80, 0.10, 0.80),
        (1.00, 1.00, 0.22, 0.15, 0.90),
    ]

    static func makeTemplate(from image: UIImage, tappedAt point: CGPoint) async throws -> MarkerTemplate {
        guard let grid = grid(for: image, height: gridHeight(for: image)) else {
            throw BuildError("Couldn't read that screenshot.")
        }
        let r = max(4, gridWidth * 11 / 1000)  // stays inside the marker's circle
        let cx = min(max(Int(point.x * CGFloat(grid.width)), r), grid.width - 1 - r)
        let cy = min(max(Int(point.y * CGFloat(grid.height)), r), grid.height - 1 - r)

        var pixels: [MarkerTemplate.Pixel] = []
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r * r {
                pixels.append(.init(dx: dx, dy: dy, value: grid[cx + dx, cy + dy]))
            }
        }

        // Anything else on this screen that looks like the marker is a decoy to ignore from now on.
        let candidate = MarkerTemplate(pixels: pixels, radius: r, decoys: [])
        var decoys: [GridPoint] = []
        for (index, score) in matchScores(grid, candidate).enumerated() where score < matchThreshold && decoys.count < 200 {
            let spot = GridPoint(x: index % grid.width + r, y: index / grid.width + r)
            let farFromTap = abs(spot.x - cx) > 3 * r || abs(spot.y - cy) > 3 * r
            let isNew = !decoys.contains { abs($0.x - spot.x) <= r && abs($0.y - spot.y) <= r }
            if farFromTap && isNew {
                decoys.append(spot)
            }
        }
        return MarkerTemplate(pixels: pixels, radius: r, decoys: decoys)
    }

    static func build(
        from screenshots: [Screenshot],
        template: MarkerTemplate,
        onProgress: @MainActor (Double) -> Void
    ) async throws -> Heatmap {
        guard let base = lastReadableImage(in: screenshots) else {
            throw BuildError("No readable screenshots for this day.")
        }
        let height = gridHeight(for: base)

        var positions: [GridPoint] = []
        for (index, screenshot) in screenshots.enumerated() {
            try Task.checkCancellation()  // stop if the heat map screen was closed
            await onProgress(Double(index) / Double(screenshots.count))
            let position = autoreleasepool { () -> GridPoint? in
                guard let image = UIImage(contentsOfFile: screenshot.url.path),
                      let grid = grid(for: image, height: height) else { return nil }
                return findMarker(in: grid, template)
            }
            if let position {
                positions.append(position)
            }
        }
        guard !positions.isEmpty else {
            throw BuildError("Goldie's marker wasn't found in any screenshot. Pick her marker again, tapping right in its center.")
        }

        // Each sighting adds a soft glow. Most sightings repeat the same spot, so add each spot once, weighted.
        let r = template.radius
        let sigma = Float(r * 2)
        let reach = Int(sigma * 3)
        var heat = [Float](repeating: 0, count: gridWidth * height)
        for (point, count) in Dictionary(positions.map { ($0, 1) }, uniquingKeysWith: +) {
            for y in max(0, point.y - reach)...min(height - 1, point.y + reach) {
                for x in max(0, point.x - reach)...min(gridWidth - 1, point.x + reach) {
                    let dx = Float(x - point.x)
                    let dy = Float(y - point.y)
                    heat[y * gridWidth + x] += Float(count) * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                }
            }
        }

        let (peakIndex, peakHeat) = vDSP.indexOfMaximum(heat)
        let peak = GridPoint(x: Int(peakIndex) % gridWidth, y: Int(peakIndex) / gridWidth)
        let nearPeak = positions.filter { abs($0.x - peak.x) <= 2 * r && abs($0.y - peak.y) <= 2 * r }.count

        guard let overlay = renderOverlay(heat, maxHeat: peakHeat, height: height) else {
            throw BuildError("Couldn't draw the heat map.")
        }
        return Heatmap(
            base: base,
            overlay: overlay,
            found: positions.count,
            total: screenshots.count,
            busiestSpot: CGPoint(x: (Double(peak.x) + 0.5) / Double(gridWidth), y: (Double(peak.y) + 0.5) / Double(height)),
            busiestSpotMinutes: nearPeak * minutesPerScreenshot
        )
    }

    /// The day's latest screenshot that opens. It's the heat map's background and the image the marker is picked on.
    static func lastReadableImage(in screenshots: [Screenshot]) -> UIImage? {
        screenshots.reversed().lazy.compactMap { UIImage(contentsOfFile: $0.url.path) }.first
    }

    private static func color(at t: Float) -> (red: Float, green: Float, blue: Float, alpha: Float) {
        let t = min(max(t, 0), 1)
        let upper = colorStops.firstIndex { $0.position >= t } ?? colorStops.count - 1
        guard upper > 0 else {
            let stop = colorStops[0]
            return (stop.red, stop.green, stop.blue, stop.alpha)
        }
        let lo = colorStops[upper - 1]
        let hi = colorStops[upper]
        let f = (t - lo.position) / (hi.position - lo.position)
        return (
            lo.red + (hi.red - lo.red) * f,
            lo.green + (hi.green - lo.green) * f,
            lo.blue + (hi.blue - lo.blue) * f,
            lo.alpha + (hi.alpha - lo.alpha) * f
        )
    }

    // MARK: - Matching

    private struct Grid {
        let width: Int
        let height: Int
        let values: [Float]  // brightness 0...1, row by row from the top

        subscript(x: Int, y: Int) -> Float {
            values[y * width + x]
        }
    }

    private static func gridHeight(for image: UIImage) -> Int {
        Int((CGFloat(gridWidth) * image.size.height / image.size.width).rounded())
    }

    private static func grid(for image: UIImage, height: Int) -> Grid? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: gridWidth * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: gridWidth,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: gridWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridWidth, height: height))
            return true
        }
        guard drawn else { return nil }
        let values = vDSP.multiply(1 / 255, vDSP.integerToFloatingPoint(bytes, floatingPointType: Float.self))
        return Grid(width: gridWidth, height: height, values: values)
    }

    /// Mean squared difference between the marker and the screen at every position,
    /// indexed by the top-left corner of the marker's bounding square. Lower is a better match.
    private static func matchScores(_ grid: Grid, _ template: MarkerTemplate) -> [Float] {
        let r = template.radius
        let count = grid.values.count - 2 * r * grid.width - 2 * r
        var scores = [Float](repeating: 0, count: count)
        var difference = [Float](repeating: 0, count: count)

        // One vectorized pass per marker pixel: scores += (screen shifted by that pixel - pixel value)²
        grid.values.withUnsafeBufferPointer { values in
            scores.withUnsafeMutableBufferPointer { scores in
                difference.withUnsafeMutableBufferPointer { difference in
                    for pixel in template.pixels {
                        let offset = (pixel.dy + r) * grid.width + (pixel.dx + r)
                        var negated = -pixel.value
                        vDSP_vsadd(values.baseAddress! + offset, 1, &negated, difference.baseAddress!, 1, vDSP_Length(count))
                        vDSP_vma(
                            difference.baseAddress!, 1, difference.baseAddress!, 1,
                            scores.baseAddress!, 1, scores.baseAddress!, 1, vDSP_Length(count)
                        )
                    }
                }
            }
        }
        scores = vDSP.multiply(1 / Float(template.pixels.count), scores)

        // Positions near the right edge wrap around onto the next row, so they don't count.
        var rowStart = 0
        while rowStart < count {
            for x in (grid.width - 2 * r)..<grid.width where rowStart + x < count {
                scores[rowStart + x] = .infinity
            }
            rowStart += grid.width
        }
        return scores
    }

    private static func findMarker(in grid: Grid, _ template: MarkerTemplate) -> GridPoint? {
        var scores = matchScores(grid, template)
        let r = template.radius
        for decoy in template.decoys {
            for y in max(0, decoy.y - 3 * r)...(decoy.y + r) {
                for x in max(0, decoy.x - 3 * r)...min(grid.width - 1, decoy.x + r) where y * grid.width + x < scores.count {
                    scores[y * grid.width + x] = .infinity
                }
            }
        }
        let (index, score) = vDSP.indexOfMinimum(scores)
        guard score < matchThreshold else { return nil }  // she's off screen, or hidden
        return GridPoint(x: Int(index) % grid.width + r, y: Int(index) / grid.width + r)
    }

    // MARK: - Drawing

    private static func renderOverlay(_ heat: [Float], maxHeat: Float, height: Int) -> UIImage? {
        var rgba = [UInt8](repeating: 0, count: heat.count * 4)
        for (index, value) in heat.enumerated() where value > 0 {
            let color = color(at: (value / maxHeat).squareRoot())  // square root keeps short visits visible
            rgba[index * 4] = UInt8(color.red * color.alpha * 255)
            rgba[index * 4 + 1] = UInt8(color.green * color.alpha * 255)
            rgba[index * 4 + 2] = UInt8(color.blue * color.alpha * 255)
            rgba[index * 4 + 3] = UInt8(color.alpha * 255)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                  width: gridWidth,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: gridWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
