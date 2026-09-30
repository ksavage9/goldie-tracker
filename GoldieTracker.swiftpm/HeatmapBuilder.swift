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
    /// Required, so a marker saved by the old brightness-difference matching (whose decoys could include
    /// blank patches of map) fails to load and is picked again.
    let matching: String
    static let currentMatching = "correlation"
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
    /// How closely the pattern must match (normalized cross-correlation, -1...1) to count as "that's Goldie".
    static let minimumCorrelation: Float = 0.8
    /// Brightness spread below which an area counts as plain (about 3%). Plain areas can't match, and a tap on one is refused.
    static let minimumVariance: Float = 0.0009
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
        let mean = pixels.reduce(0) { $0 + $1.value } / Float(pixels.count)
        let variance = pixels.reduce(0) { $0 + ($1.value - mean) * ($1.value - mean) } / Float(pixels.count)
        guard variance >= minimumVariance else {
            throw BuildError("That spot is too plain to be Goldie's marker. Pick her marker again, tapping right in its center.")
        }

        // Anything else on this screen that looks like the marker is a decoy to ignore from now on.
        let candidate = MarkerTemplate(pixels: pixels, radius: r, decoys: [], matching: MarkerTemplate.currentMatching)
        var decoys: [GridPoint] = []
        for (index, score) in matchScores(grid, candidate).enumerated() where score >= minimumCorrelation && decoys.count < 200 {
            let spot = GridPoint(x: index % grid.width + r, y: index / grid.width + r)
            let farFromTap = abs(spot.x - cx) > 3 * r || abs(spot.y - cy) > 3 * r
            let isNew = !decoys.contains { abs($0.x - spot.x) <= r && abs($0.y - spot.y) <= r }
            if farFromTap && isNew {
                decoys.append(spot)
            }
        }
        return MarkerTemplate(pixels: pixels, radius: r, decoys: decoys, matching: MarkerTemplate.currentMatching)
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

    /// How well the marker's pattern matches the screen at every position, from -1 to 1 (normalized
    /// cross-correlation), indexed by the top-left corner of the marker's bounding square. Higher is better.
    /// It compares the pattern of light and dark, not brightness itself, so plain areas (empty map, blank
    /// sidebar) score near 0 even when a light-colored marker is as bright as they are.
    private static func matchScores(_ grid: Grid, _ template: MarkerTemplate) -> [Float] {
        let r = template.radius
        let n = Float(template.pixels.count)
        let count = grid.values.count - 2 * r * grid.width - 2 * r
        let mean = template.pixels.reduce(0) { $0 + $1.value } / n
        let weights = template.pixels.map { $0.value - mean }  // the marker with its average brightness removed
        let templateNorm = weights.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let squares = vDSP.multiply(grid.values, grid.values)
        var products = [Float](repeating: 0, count: count)
        var sums = [Float](repeating: 0, count: count)
        var sumsOfSquares = [Float](repeating: 0, count: count)

        // One vectorized pass per marker pixel, adding up the screen under the marker three ways.
        grid.values.withUnsafeBufferPointer { values in
            squares.withUnsafeBufferPointer { squares in
                products.withUnsafeMutableBufferPointer { products in
                    sums.withUnsafeMutableBufferPointer { sums in
                        sumsOfSquares.withUnsafeMutableBufferPointer { sumsOfSquares in
                            for (pixel, weight) in zip(template.pixels, weights) {
                                let offset = (pixel.dy + r) * grid.width + (pixel.dx + r)
                                var weight = weight
                                vDSP_vsma(values.baseAddress! + offset, 1, &weight, products.baseAddress!, 1, products.baseAddress!, 1, vDSP_Length(count))
                                vDSP_vadd(values.baseAddress! + offset, 1, sums.baseAddress!, 1, sums.baseAddress!, 1, vDSP_Length(count))
                                vDSP_vadd(squares.baseAddress! + offset, 1, sumsOfSquares.baseAddress!, 1, sumsOfSquares.baseAddress!, 1, vDSP_Length(count))
                            }
                        }
                    }
                }
            }
        }

        // correlation = products / (templateNorm × √(the screen's spread under the marker)). The spread has a
        // floor, so a plain area's tiny noise can't be divided into a high score.
        let spread = vDSP.subtract(sumsOfSquares, vDSP.multiply(1 / n, vDSP.multiply(sums, sums)))
        let floored = vDSP.clip(spread, to: (n * minimumVariance)...Float.greatestFiniteMagnitude)
        var scores = vDSP.divide(products, vDSP.multiply(templateNorm, vForce.sqrt(floored)))

        // Positions near the right edge wrap around onto the next row, so they don't count.
        var rowStart = 0
        while rowStart < count {
            for x in (grid.width - 2 * r)..<grid.width where rowStart + x < count {
                scores[rowStart + x] = -.infinity
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
                    scores[y * grid.width + x] = -.infinity
                }
            }
        }
        let (index, score) = vDSP.indexOfMaximum(scores)
        guard score >= minimumCorrelation else { return nil }  // she's off screen, or hidden
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
