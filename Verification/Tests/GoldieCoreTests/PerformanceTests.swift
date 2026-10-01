import AVFoundation
import XCTest
@testable import GoldieCore

/// Times the two heavy jobs on full-size (2732 × 2048) screenshots, like a real iPad's, and prints the cost per
/// screenshot so changes can be compared run to run. The limits are generous: GitHub's simulators vary a lot.
@MainActor
final class PerformanceTests: XCTestCase {
    private let fullSize = CGSize(width: 2732, height: 2048)

    private func fullSizeDay(_ name: String, count: Int) throws -> [Screenshot] {
        let folder = try Fixtures.makeTemporaryFolder(name)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return try (0..<count).map { i in
            let marker = CGPoint(x: 1200 + Double(i % 6) * 60, y: 600 + Double(i / 6) * 40)
            return try Fixtures.write(Fixtures.screenshot(marker: marker, size: fullSize), to: folder.appending(path: "\(i).jpg"), created: start + Double(i) * 300)
        }
    }

    func testHeatMapSpeed() async throws {
        let shots = try fullSizeDay("perf-heatmap", count: 24)
        let reference = try XCTUnwrap(UIImage(contentsOfFile: shots[0].url.path))
        let template = try await HeatmapBuilder.makeTemplate(from: reference, tappedAt: CGPoint(x: 1200 / fullSize.width, y: 600 / fullSize.height))
        let start = Date()
        let heatmap = try await HeatmapBuilder.build(from: shots, template: template) { _ in }
        let perScreenshot = Date().timeIntervalSince(start) / Double(shots.count)
        print("PERF heat map: \(Int(perScreenshot * 1000)) ms per screenshot (\(shots.count) full-size screenshots, found \(heatmap.found))")
        XCTAssertLessThan(perScreenshot, 1.5, "a day of 288 screenshots should take a few minutes at most, even on a slow simulator")
    }

    /// Breaks a heat map's cost per screenshot down: decoding, making the grids, finding her marker on the
    /// full grid, and the alignment search on the coarse grid (only needed when the map moved).
    func testHeatMapCostBreakdown() throws {
        let shots = try fullSizeDay("perf-heat-parts", count: 12)
        func time(_ label: String, _ work: () -> Void) {
            let start = Date()
            for _ in 0..<12 { work() }
            print("PERF heat map \(label): \(String(format: "%.1f", Date().timeIntervalSince(start) / 12 * 1000)) ms")
        }
        var image: CGImage?
        var index = 0
        time("decode at 640") {
            image = ImageFile.downsampled(shots[index % 12].url, maxPixelSize: 640)
            index += 1
        }
        let decoded = try XCTUnwrap(image)
        var grid: HeatmapBuilder.Grid?
        time("full and coarse grids") {
            grid = HeatmapBuilder.grid(from: decoded, width: 640, height: 480)
            _ = HeatmapBuilder.grid(from: decoded, width: 160, height: 120)
        }
        let screen = try XCTUnwrap(grid)
        let coarse = try XCTUnwrap(HeatmapBuilder.grid(from: decoded, width: 160, height: 120))
        let r = 7
        var disc: [MarkerTemplate.Pixel] = []
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r * r {
                disc.append(.init(dx: dx + r, dy: dy + r, value: screen[320 + dx, 240 + dy]))
            }
        }
        time("marker search") { _ = HeatmapBuilder.correlate(screen, disc, width: 2 * r + 1, height: 2 * r + 1) }
        var block: [MarkerTemplate.Pixel] = []
        for dy in stride(from: 0, to: 72, by: 2) {
            for dx in stride(from: 0, to: 64, by: 2) {
                block.append(.init(dx: dx, dy: dy, value: coarse[70 + dx, 26 + dy]))
            }
        }
        time("alignment search") { _ = HeatmapBuilder.correlate(coarse, block, width: 64, height: 72) }
    }

    /// A month of screenshots (30 days × 288) is about 8,640 files. Scanning them runs on the main thread every
    /// minute, so it must stay quick.
    func testFolderScanSpeedWithAMonthOfScreenshots() throws {
        let folder = try Fixtures.makeTemporaryFolder("perf-month")
        let today = Calendar.current.startOfDay(for: .now)
        for day in 0..<30 {
            let dayStart = Calendar.current.date(byAdding: .day, value: -day, to: today)!
            for i in 0..<288 {
                let url = folder.appending(path: "\(day)-\(i).jpg")
                FileManager.default.createFile(atPath: url.path, contents: Data(count: 16))
                try FileManager.default.setAttributes([.creationDate: dayStart + Double(i) * 300], ofItemAtPath: url.path)
            }
        }
        UserDefaults.standard.removeObject(forKey: "screenshotFolderBookmark")
        try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: "Animations"))  // left by other tests
        let store = Store()
        store.setFolder(folder)
        XCTAssertEqual(store.days.count, 30)
        let start = Date()
        for _ in 0..<5 {
            store.refresh()
        }
        let perScan = Date().timeIntervalSince(start) / 5
        print("PERF folder scan: \(Int(perScan * 1000)) ms for 8,640 screenshots")
        XCTAssertLessThan(perScan, 0.5, "this runs on the main thread every minute")
        UserDefaults.standard.removeObject(forKey: "screenshotFolderBookmark")
    }

    /// Breaks the animation's cost down: decoding, drawing a frame, starting the encoder, and the whole build
    /// for 1366- and 2732-wide sources.
    func testAnimationCostBreakdown() async throws {
        let small = try (0..<12).map { i in
            try Fixtures.write(Fixtures.screenshot(marker: CGPoint(x: 600, y: 300)), to: Fixtures.makeTemporaryFolder("perf-small-\(i)").appending(path: "s.jpg"), created: Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 300))
        }
        let large = try fullSizeDay("perf-large", count: 12)

        var start = Date()
        for shot in large { _ = ImageFile.downsampled(shot.url, maxPixelSize: 1280) }
        print("PERF decode one 2732-wide screenshot at 1280: \(Int(Date().timeIntervalSince(start) / 12 * 1000)) ms")

        // Timed before the encoder first starts: starting it keeps the simulator busy for a while afterwards.
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1280,
            kCVPixelBufferHeightKey as String: 958,
        ] as CFDictionary, &pool)
        start = Date()
        for shot in large { _ = VideoBuilder.makeFrame(shot, size: CGSize(width: 1280, height: 958), showsDate: false, pool: pool) }
        let drawPerFrame = Date().timeIntervalSince(start) / 12
        print("PERF draw one frame from a 2732-wide screenshot: \(Int(drawPerFrame * 1000)) ms")
        XCTAssertLessThan(drawPerFrame, 1.0, "the app's own share of each frame; the rest is the encoder")

        let output = FileManager.default.temporaryDirectory.appending(path: "perf-\(UUID().uuidString).mp4")
        start = Date()
        try await VideoBuilder.makeVideo(from: [small[0]], to: output) { _ in }
        print("PERF first one-frame animation (encoder start-up): \(Int(Date().timeIntervalSince(start) * 1000)) ms")

        for (label, shots) in [("1366-wide", small), ("2732-wide", large)] {
            let output = FileManager.default.temporaryDirectory.appending(path: "perf-\(UUID().uuidString).mp4")
            start = Date()
            try await VideoBuilder.makeVideo(from: shots, to: output) { _ in }
            print("PERF animation from \(label) screenshots: \(Int(Date().timeIntervalSince(start) / 12 * 1000)) ms per frame")
        }
    }

    func testAnimationSpeed() async throws {
        let shots = try fullSizeDay("perf-video", count: 24)
        // The simulator's software encoder takes a long time to start the first time; that isn't per-frame cost.
        let warmUp = FileManager.default.temporaryDirectory.appending(path: "perf-\(UUID().uuidString).mp4")
        try await VideoBuilder.makeVideo(from: [shots[0]], to: warmUp) { _ in }
        let output = FileManager.default.temporaryDirectory.appending(path: "perf-\(UUID().uuidString).mp4")
        let start = Date()
        try await VideoBuilder.makeVideo(from: shots, to: output) { _ in }
        let perFrame = Date().timeIntervalSince(start) / Double(shots.count)
        print("PERF animation: \(Int(perFrame * 1000)) ms per frame (\(shots.count) full-size screenshots)")
        XCTAssertLessThan(perFrame, 1.5)
    }
}
