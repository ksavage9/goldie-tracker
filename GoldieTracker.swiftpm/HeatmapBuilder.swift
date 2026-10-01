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
    let skipped: Int  // screenshots whose map was zoomed or moved too far to line up with the background
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
    /// The first sighting of the day has no earlier screenshot to compare with, so it must match very closely.
    static let firstSightingCorrelation: Float = 0.9
    /// Average brightness change that means something appeared or moved at a spot between two screenshots.
    static let changeThreshold: Float = 0.035
    /// Screenshots are lined up on a grid shrunk this many times more, which is plenty for the map's position.
    static let alignmentScale = 4
    /// How closely a screenshot's map must match the background's to be lined up with it.
    static let minimumAlignment: Float = 0.7
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
        guard let baseGrid = grid(for: base, height: height) else {
            throw BuildError("Couldn't read the day's screenshots.")
        }
        // The heat is drawn over the day's last screenshot. Each screenshot is lined up with it first, so a
        // sighting lands on the right part of the map even if the map moved a little.
        let alignmentPatch = makeAlignmentPatch(from: coarse(baseGrid))
        let r = template.radius

        var positions: [GridPoint] = []  // in the background screenshot's coordinates
        var skipped = 0
        var previous: (grid: Grid, shift: GridPoint)?  // the last screenshot that lined up
        var lastSighting: GridPoint?
        for (index, screenshot) in screenshots.enumerated() {
            try Task.checkCancellation()  // stop if the heat map screen was closed
            await onProgress(Double(index) / Double(screenshots.count))
            let loaded = autoreleasepool { () -> (grid: Grid, shift: GridPoint?)? in
                guard let image = UIImage(contentsOfFile: screenshot.url.path),
                      let grid = grid(for: image, height: height) else { return nil }
                // A plain background can't be lined up, so screenshots are then taken as they are.
                let shift = alignmentPatch.map { align(coarse(grid), with: $0) } ?? GridPoint(x: 0, y: 0)
                return (grid, shift)
            }
            guard let loaded else { continue }  // unreadable file
            guard let shift = loaded.shift else {
                skipped += 1  // zoomed, moved too far, or not the map at all
                continue
            }
            // Not called `grid`: that name inside the closure above would then mean this, not the grid(for:) function.
            let screen = loaded.grid
            defer { previous = (screen, shift) }

            guard let (spot, score) = findMarker(in: screen, template) else { continue }  // she's off screen, or hidden
            let inBackground = GridPoint(x: spot.x + shift.x, y: spot.y + shift.y)
            guard (0..<gridWidth).contains(inBackground.x), (0..<height).contains(inBackground.y) else { continue }

            // Compare with the screenshot before: a sighting in a new place only counts if something actually
            // changed there. A look-alike that sits still (an icon or label on the map) changes nothing.
            if let lastSighting, abs(inBackground.x - lastSighting.x) <= 2 * r, abs(inBackground.y - lastSighting.y) <= 2 * r {
                // Same place as last time.
            } else if let previous {
                let before = GridPoint(x: inBackground.x - previous.shift.x, y: inBackground.y - previous.shift.y)
                guard changed(screen, at: spot, comparedWith: previous.grid, at: before, radius: r) else { continue }
            } else {
                guard score >= firstSightingCorrelation else { continue }
            }
            positions.append(inBackground)
            lastSighting = inBackground
        }
        guard !positions.isEmpty else {
            throw BuildError(skipped > 0
                ? "Goldie's marker wasn't found. \(skipped) screenshots were skipped because the map was zoomed or moved. Keep Find My's map still, or pick her marker again."
                : "Goldie's marker wasn't found in any screenshot. Pick her marker again, tapping right in its center.")
        }

        // Each sighting adds a soft glow. Most sightings repeat the same spot, so add each spot once, weighted.
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
            skipped: skipped,
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
        let fromCorner = template.pixels.map { MarkerTemplate.Pixel(dx: $0.dx + r, dy: $0.dy + r, value: $0.value) }
        return correlate(grid, fromCorner, width: 2 * r + 1, height: 2 * r + 1)
    }

    /// Normalized cross-correlation of a patch at every position where it fits. `patch` pixels are measured
    /// from the patch's top-left corner, and so is the result's index. Positions that don't fit score -infinity.
    private static func correlate(_ grid: Grid, _ patch: [MarkerTemplate.Pixel], width patchWidth: Int, height patchHeight: Int) -> [Float] {
        let n = Float(patch.count)
        let count = grid.values.count - (patchHeight - 1) * grid.width - (patchWidth - 1)
        let mean = patch.reduce(0) { $0 + $1.value } / n
        let weights = patch.map { $0.value - mean }  // the patch with its average brightness removed
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
                            for (pixel, weight) in zip(patch, weights) {
                                let offset = pixel.dy * grid.width + pixel.dx
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
            for x in (grid.width - patchWidth + 1)..<grid.width where rowStart + x < count {
                scores[rowStart + x] = -.infinity
            }
            rowStart += grid.width
        }
        return scores
    }

    // MARK: - Lining screenshots up

    /// A block of the background screenshot's map, used to find where the map sits in other screenshots.
    private struct AlignmentPatch {
        let pixels: [MarkerTemplate.Pixel]
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// The grid shrunk by `alignmentScale`, averaging each block.
    private static func coarse(_ grid: Grid) -> Grid {
        let s = alignmentScale
        let width = grid.width / s, height = grid.height / s
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var total: Float = 0
                for dy in 0..<s {
                    for dx in 0..<s {
                        total += grid[x * s + dx, y * s + dy]
                    }
                }
                values[y * width + x] = total / Float(s * s)
            }
        }
        return Grid(width: width, height: height, values: values)
    }

    /// The middle-right of the screen, where Find My shows the map: clear of the sidebar on the left and
    /// the status bar at the top. nil when it's too plain to line anything up with.
    private static func makeAlignmentPatch(from coarseBase: Grid) -> AlignmentPatch? {
        let x = coarseBase.width * 44 / 100, width = coarseBase.width * 40 / 100
        let y = coarseBase.height * 22 / 100, height = coarseBase.height * 60 / 100
        var pixels: [MarkerTemplate.Pixel] = []
        for dy in 0..<height {
            for dx in 0..<width {
                pixels.append(.init(dx: dx, dy: dy, value: coarseBase[x + dx, y + dy]))
            }
        }
        let mean = pixels.reduce(0) { $0 + $1.value } / Float(pixels.count)
        let variance = pixels.reduce(0) { $0 + ($1.value - mean) * ($1.value - mean) } / Float(pixels.count)
        guard variance >= minimumVariance else { return nil }
        return AlignmentPatch(pixels: pixels, x: x, y: y, width: width, height: height)
    }

    /// How far to move a screenshot's points (in grid pixels) to land on the same map spot in the background,
    /// or nil when its map doesn't line up: zoomed, moved too far, or not showing the map.
    private static func align(_ coarseGrid: Grid, with patch: AlignmentPatch) -> GridPoint? {
        let (index, score) = vDSP.indexOfMaximum(correlate(coarseGrid, patch.pixels, width: patch.width, height: patch.height))
        guard score >= minimumAlignment else { return nil }
        let foundX = Int(index) % coarseGrid.width, foundY = Int(index) / coarseGrid.width
        return GridPoint(x: (patch.x - foundX) * alignmentScale, y: (patch.y - foundY) * alignmentScale)
    }

    /// Whether the screen changed at a spot between two screenshots: something appeared, left or moved there.
    private static func changed(_ grid: Grid, at spot: GridPoint, comparedWith other: Grid, at otherSpot: GridPoint, radius r: Int) -> Bool {
        guard otherSpot.x >= r, otherSpot.y >= r, otherSpot.x < other.width - r, otherSpot.y < other.height - r else {
            return true  // that spot was off the earlier screen
        }
        var total: Float = 0
        var count = 0
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r * r {
                total += abs(grid[spot.x + dx, spot.y + dy] - other[otherSpot.x + dx, otherSpot.y + dy])
                count += 1
            }
        }
        return total / Float(count) > changeThreshold
    }

    /// The best match for her marker, if it's good enough, and how good it was.
    private static func findMarker(in grid: Grid, _ template: MarkerTemplate) -> (spot: GridPoint, score: Float)? {
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
        return (GridPoint(x: Int(index) % grid.width + r, y: Int(index) / grid.width + r), score)
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
