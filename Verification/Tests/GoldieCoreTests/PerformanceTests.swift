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

    func testAnimationSpeed() async throws {
        let shots = try fullSizeDay("perf-video", count: 24)
        let output = FileManager.default.temporaryDirectory.appending(path: "perf-\(UUID().uuidString).mp4")
        let start = Date()
        try await VideoBuilder.makeVideo(from: shots, to: output) { _ in }
        let perFrame = Date().timeIntervalSince(start) / Double(shots.count)
        print("PERF animation: \(Int(perFrame * 1000)) ms per frame (\(shots.count) full-size screenshots)")
        XCTAssertLessThan(perFrame, 1.5)
    }
}
