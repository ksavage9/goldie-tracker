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
    /// A screenshot whose map matches the background this well where it stands hasn't moved, so no search is needed.
    static let unmovedCorrelation: Float = 0.95
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
        guard let (baseScreenshot, base) = lastReadable(in: screenshots) else {
            throw BuildError("No readable screenshots for this day.")
        }
        let height = gridHeight(for: base)
        let coarseWidth = gridWidth / alignmentScale, coarseHeight = height / alignmentScale
        // Every screenshot, the background included, is decoded straight at grid size, the same way, so their
        // grids compare fairly; that's also much faster than decoding the full screenshot.
        let maxPixelSize = max(gridWidth, height)
        guard let baseImage = ImageFile.downsampled(baseScreenshot.url, maxPixelSize: maxPixelSize),
              let coarseBase = grid(from: baseImage, width: coarseWidth, height: coarseHeight) else {
            throw BuildError("Couldn't read the day's screenshots.")
        }
        // The heat is drawn over the day's last screenshot. Each screenshot is lined up with it first, so a
        // sighting lands on the right part of the map even if the map moved a little.
        let alignmentPatch = makeAlignmentPatch(from: coarseBase)
        let r = template.radius

        // Pass 1: in each screenshot that lines up, the best match for her marker (a candidate), whether the
        // screen changed where it is since the screenshot before (she arrived), and, once the next screenshot is
        // in, whether it changed there afterwards (she left).
        struct Candidate {
            let spot: GridPoint  // in the background screenshot's coordinates
            let score: Float
            let arrived: Bool
            var left = false
            let isFirstOfDay: Bool  // nothing earlier to compare with
        }
        var candidates: [Candidate] = []
        var skipped = 0
        var previous: (grid: Grid, shift: GridPoint)?  // the last screenshot that lined up
        for (index, screenshot) in screenshots.enumerated() {
            try Task.checkCancellation()  // stop if the heat map screen was closed
            await onProgress(Double(index) / Double(screenshots.count))
            let loaded = autoreleasepool { () -> (grid: Grid, shift: GridPoint?)? in
                // Self.grid: a plain `grid(...)` after `let grid` would mean the local value, not the function.
                guard let image = ImageFile.downsampled(screenshot.url, maxPixelSize: maxPixelSize),
                      let grid = Self.grid(from: image, width: gridWidth, height: height),
                      let coarseGrid = Self.grid(from: image, width: coarseWidth, height: coarseHeight) else { return nil }
                // A plain background can't be lined up, so screenshots are then taken as they are.
                let shift = alignmentPatch.map { align(coarseGrid, with: $0) } ?? GridPoint(x: 0, y: 0)
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

            if let previous, let last = candidates.indices.last, !candidates[last].left {
                let spot = candidates[last].spot
                let here = GridPoint(x: spot.x - shift.x, y: spot.y - shift.y)
                let before = GridPoint(x: spot.x - previous.shift.x, y: spot.y - previous.shift.y)
                if here.x >= r, here.y >= r, here.x < screen.width - r, here.y < screen.height - r,
                   changed(screen, at: here, comparedWith: previous.grid, at: before, radius: r) {
                    candidates[last].left = true
                }
            }

            guard let (spot, score) = findMarker(in: screen, template) else { continue }  // she's off screen, or hidden
            let inBackground = GridPoint(x: spot.x + shift.x, y: spot.y + shift.y)
            guard (0..<gridWidth).contains(inBackground.x), (0..<height).contains(inBackground.y) else { continue }
            let arrived = previous.map { previous in
                changed(screen, at: spot, comparedWith: previous.grid,
                        at: GridPoint(x: inBackground.x - previous.shift.x, y: inBackground.y - previous.shift.y), radius: r)
            } ?? false
            candidates.append(Candidate(spot: inBackground, score: score, arrived: arrived, isFirstOfDay: previous == nil))
        }

        // Pass 2: judge each stay at one spot as a whole. It counts if she arrived there or left it (the screen
        // changed), or, at the start of the day with nothing earlier to compare, if it matches very closely.
        // A look-alike that sits still never arrives or leaves, so it isn't counted.
        var positions: [GridPoint] = []
        var runStart = 0
        while runStart < candidates.count {
            var runEnd = runStart
            while runEnd + 1 < candidates.count,
                  abs(candidates[runEnd + 1].spot.x - candidates[runStart].spot.x) <= 2 * r,
                  abs(candidates[runEnd + 1].spot.y - candidates[runStart].spot.y) <= 2 * r {
                runEnd += 1
            }
            let stay = candidates[runStart...runEnd]
            let counts = stay.first!.arrived
                || stay.contains { $0.left }
                || (stay.first!.isFirstOfDay && stay.contains { $0.score >= firstSightingCorrelation })
            if counts {
                positions += stay.map(\.spot)
            }
            runStart = runEnd + 1
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

    /// Largest side of the background image shown on screen: sharp on an iPad, and decoded in the background
    /// (async) rather than all 2732 × 2048 pixels on the main thread when it's first drawn.
    private static let displayPixelSize = 2048

    /// The day's latest screenshot that opens. It's the heat map's background and the image the marker is picked on.
    static func lastReadableImage(in screenshots: [Screenshot]) async -> UIImage? {
        lastReadable(in: screenshots)?.image
    }

    private static func lastReadable(in screenshots: [Screenshot]) -> (screenshot: Screenshot, image: UIImage)? {
        for screenshot in screenshots.reversed() {
            if let image = ImageFile.downsampled(screenshot.url, maxPixelSize: displayPixelSize) {
                return (screenshot, UIImage(cgImage: image))
            }
        }
        return nil
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

    struct Grid {
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
        image.cgImage.flatMap { grid(from: $0, width: gridWidth, height: height) }
    }

    /// The image drawn in grayscale at the given size. Drawing smaller averages the detail away, which is how
    /// the shrunken alignment grid is made.
    static func grid(from image: CGImage, width: Int, height: Int) -> Grid? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let values = vDSP.multiply(1 / 255, vDSP.integerToFloatingPoint(bytes, floatingPointType: Float.self))
        return Grid(width: width, height: height, values: values)
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
    static func correlate(_ grid: Grid, _ patch: [MarkerTemplate.Pixel], width patchWidth: Int, height patchHeight: Int) -> [Float] {
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

    /// The middle-right of the screen, where Find My shows the map: clear of the sidebar on the left and
    /// the status bar at the top. nil when it's too plain to line anything up with.
    private static func makeAlignmentPatch(from coarseBase: Grid) -> AlignmentPatch? {
        let x = coarseBase.width * 44 / 100, width = coarseBase.width * 40 / 100
        let y = coarseBase.height * 22 / 100, height = coarseBase.height * 60 / 100
        var pixels: [MarkerTemplate.Pixel] = []
        // Every other pixel each way: plenty to find the map's position, and a quarter of the work.
        for dy in stride(from: 0, to: height, by: 2) {
            for dx in stride(from: 0, to: width, by: 2) {
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
        // Usually the map hasn't moved. Checking that one position first is far cheaper than searching everywhere.
        if correlationInPlace(coarseGrid, patch) >= unmovedCorrelation {
            return GridPoint(x: 0, y: 0)
        }
        let (index, score) = vDSP.indexOfMaximum(correlate(coarseGrid, patch.pixels, width: patch.width, height: patch.height))
        guard score >= minimumAlignment else { return nil }
        let foundX = Int(index) % coarseGrid.width, foundY = Int(index) / coarseGrid.width
        return GridPoint(x: (patch.x - foundX) * alignmentScale, y: (patch.y - foundY) * alignmentScale)
    }

    /// How well the patch matches the screen at the same position it came from (-1...1).
    private static func correlationInPlace(_ grid: Grid, _ patch: AlignmentPatch) -> Float {
        guard patch.x + patch.width <= grid.width, patch.y + patch.height <= grid.height else { return -1 }
        let n = Float(patch.pixels.count)
        let screen = patch.pixels.map { grid[patch.x + $0.dx, patch.y + $0.dy] }
        let patchMean = patch.pixels.reduce(0) { $0 + $1.value } / n
        let screenMean = screen.reduce(0, +) / n
        var products: Float = 0, patchSquares: Float = 0, screenSquares: Float = 0
        for (pixel, value) in zip(patch.pixels, screen) {
            let a = pixel.value - patchMean, b = value - screenMean
            products += a * b
            patchSquares += a * a
            screenSquares += b * b
        }
        return products / max((patchSquares * screenSquares).squareRoot(), .leastNonzeroMagnitude)
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
