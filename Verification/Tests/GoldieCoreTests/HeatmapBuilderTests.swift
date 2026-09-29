import XCTest
@testable import GoldieCore

/// The real HeatmapBuilder (Accelerate matching) on synthetic Find My screenshots saved as JPEGs.
@MainActor
final class HeatmapBuilderTests: XCTestCase {
    func testFindsGoldieInEveryScreenshotAndMarksHerBusiestSpot() async throws {
        let folder = try Fixtures.makeTemporaryFolder("heatmap")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let home = CGPoint(x: 600, y: 300), street = CGPoint(x: 1000, y: 750), park = CGPoint(x: 450, y: 900)
        let plan: [CGPoint?] = Array(repeating: home, count: 10) + Array(repeating: street, count: 6)
            + Array(repeating: park, count: 4) + [nil, nil]  // last two: off screen
        var screenshots: [Screenshot] = []
        for (i, marker) in plan.enumerated() {
            screenshots.append(try Fixtures.write(Fixtures.screenshot(marker: marker), to: folder.appending(path: "\(i).jpg"), created: start + Double(i) * 300))
        }

        // Calibrate like a person would: a tap a few pixels off her marker's center.
        let reference = try XCTUnwrap(UIImage(contentsOfFile: screenshots[0].url.path))
        let tap = CGPoint(x: (home.x + 3) / Fixtures.size.width, y: (home.y - 2) / Fixtures.size.height)
        let template = try await HeatmapBuilder.makeTemplate(from: reference, tappedAt: tap)
        XCTAssertFalse(template.decoys.isEmpty, "her icon in the Find My list should be recognized as a decoy")

        let heatmap = try await HeatmapBuilder.build(from: screenshots, template: template) { _ in }

        XCTAssertEqual(heatmap.total, 22)
        XCTAssertEqual(heatmap.found, 20, "found in every screenshot where she's on the map, and only those")
        XCTAssertEqual(heatmap.busiestSpot.x, home.x / Fixtures.size.width, accuracy: 0.02)
        XCTAssertEqual(heatmap.busiestSpot.y, home.y / Fixtures.size.height, accuracy: 0.02)
        XCTAssertEqual(heatmap.busiestSpotMinutes, 50, "10 screenshots at home × 5 minutes")
        XCTAssertEqual(heatmap.overlay.size.width, 640)
        XCTAssertEqual(heatmap.overlay.size.height, 480)

        // The saved marker must survive being written to disk and read back.
        let decoded = try JSONDecoder().decode(MarkerTemplate.self, from: JSONEncoder().encode(template))
        XCTAssertEqual(decoded.pixels.count, template.pixels.count)
        XCTAssertEqual(decoded.decoys, template.decoys)
    }

    func testUsesTheLatestReadableScreenshotAsTheBackground() async throws {
        let folder = try Fixtures.makeTemporaryFolder("heatmap-readable")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let good = try Fixtures.write(Fixtures.screenshot(marker: CGPoint(x: 600, y: 300)), to: folder.appending(path: "good.jpg"), created: start)
        let badURL = folder.appending(path: "bad.jpg")
        try Data("not an image".utf8).write(to: badURL)
        let bad = Screenshot(url: badURL, date: start + 300, bytes: 12)

        XCTAssertNotNil(HeatmapBuilder.lastReadableImage(in: [good, bad]), "an unreadable last file is skipped")
        XCTAssertNil(HeatmapBuilder.lastReadableImage(in: [bad]))
    }
}
