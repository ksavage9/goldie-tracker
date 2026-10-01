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

    /// A golden cat's marker is nearly as light as the map in grayscale. The old brightness-difference
    /// matching "found" her on plain patches of map in screenshots where she was off screen.
    func testALightColoredMarkerIsNotFoundOnPlainMap() async throws {
        let folder = try Fixtures.makeTemporaryFolder("heatmap-light")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let golden = UIColor(red: 1.0, green: 0.88, blue: 0.55, alpha: 1)
        let home = CGPoint(x: 600, y: 300), street = CGPoint(x: 1000, y: 750)
        let plan: [CGPoint?] = Array(repeating: home, count: 10) + Array(repeating: street, count: 6)
            + Array(repeating: nil, count: 6)  // off screen
        var screenshots: [Screenshot] = []
        for (i, marker) in plan.enumerated() {
            screenshots.append(try Fixtures.write(Fixtures.screenshot(marker: marker, face: golden), to: folder.appending(path: "\(i).jpg"), created: start + Double(i) * 300))
        }
        let reference = try XCTUnwrap(UIImage(contentsOfFile: screenshots[0].url.path))
        let tap = CGPoint(x: (home.x + 3) / Fixtures.size.width, y: (home.y - 2) / Fixtures.size.height)
        let template = try await HeatmapBuilder.makeTemplate(from: reference, tappedAt: tap)
        XCTAssertLessThanOrEqual(template.decoys.count, 2, "only her sidebar icon should be a decoy, not blank patches of map")

        let heatmap = try await HeatmapBuilder.build(from: screenshots, template: template) { _ in }
        XCTAssertEqual(heatmap.found, 16, "found in the 16 screenshots where she's on the map, and none of the 6 where she isn't")
        XCTAssertEqual(heatmap.busiestSpot.x, home.x / Fixtures.size.width, accuracy: 0.02)
        XCTAssertEqual(heatmap.busiestSpot.y, home.y / Fixtures.size.height, accuracy: 0.02)
    }

    // MARK: - Ghost sightings (Goldie "in the middle of a lake")

    private func screenshots(_ images: [UIImage], in name: String) throws -> [Screenshot] {
        let folder = try Fixtures.makeTemporaryFolder(name)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return try images.enumerated().map { i, image in
            try Fixtures.write(image, to: folder.appending(path: "\(i).jpg"), created: start + Double(i) * 300)
        }
    }

    private func calibrate(on screenshot: Screenshot, tapAt spot: CGPoint) async throws -> MarkerTemplate {
        let image = try XCTUnwrap(UIImage(contentsOfFile: screenshot.url.path))
        return try await HeatmapBuilder.makeTemplate(from: image, tappedAt: CGPoint(x: (spot.x + 3) / Fixtures.size.width, y: (spot.y - 2) / Fixtures.size.height))
    }

    /// Find My re-centers the map when she moves. Her sightings must still land on the right part of the background map.
    func testRecenteredMapStillPutsHerInTheRightPlace() async throws {
        let home = CGPoint(x: 600, y: 300), street = CGPoint(x: 1000, y: 750)
        let moved = CGPoint(x: -90, y: -50)
        let images = (0..<14).map { i in
            i < 8 ? Fixtures.screenshot(marker: home) : Fixtures.screenshot(marker: street, mapOffset: moved)
        }
        let shots = try screenshots(images, in: "heatmap-recentered")
        let template = try await calibrate(on: shots[0], tapAt: home)
        let heatmap = try await HeatmapBuilder.build(from: shots, template: template) { _ in }
        XCTAssertEqual(heatmap.found, 14)
        XCTAssertEqual(heatmap.skipped, 0)
        // The background is the last screenshot, whose map is moved, so home appears at home + moved there.
        XCTAssertEqual(heatmap.busiestSpot.x, (home.x + moved.x) / Fixtures.size.width, accuracy: 0.02, "home lined up with the background's map")
        XCTAssertEqual(heatmap.busiestSpot.y, (home.y + moved.y) / Fixtures.size.height, accuracy: 0.02)
    }

    /// Screenshots showing a different view (zoomed out) can't be lined up, so they're skipped instead of
    /// drawn over the wrong part of the map.
    func testZoomedOutScreenshotsAreSkipped() async throws {
        let home = CGPoint(x: 600, y: 300)
        let images = (0..<10).map { i in
            [3, 6].contains(i) ? Fixtures.screenshot(marker: CGPoint(x: 900, y: 210), zoomedOut: true) : Fixtures.screenshot(marker: home)
        }
        let shots = try screenshots(images, in: "heatmap-zoomed")
        let template = try await calibrate(on: shots[0], tapAt: home)
        let heatmap = try await HeatmapBuilder.build(from: shots, template: template) { _ in }
        XCTAssertEqual(heatmap.skipped, 2)
        XCTAssertEqual(heatmap.found, 8)
        XCTAssertEqual(heatmap.busiestSpot.x, home.x / Fixtures.size.width, accuracy: 0.02)
    }

    /// A look-alike that appears and then sits still (another item, an icon on the map) isn't Goldie,
    /// even once she's off screen and it's the best match left.
    func testAStillLookAlikeIsNotCounted() async throws {
        let home = CGPoint(x: 600, y: 300), inTheLake = CGPoint(x: 910, y: 210)
        let images = (0..<14).map { i in
            Fixtures.screenshot(marker: i < 7 ? home : nil, lookalike: i >= 3 ? inTheLake : nil)
        }
        let shots = try screenshots(images, in: "heatmap-lookalike")
        let template = try await calibrate(on: shots[0], tapAt: home)
        let heatmap = try await HeatmapBuilder.build(from: shots, template: template) { _ in }
        XCTAssertEqual(heatmap.found, 7, "only the 7 real sightings at home, none in the lake")
        XCTAssertEqual(heatmap.busiestSpot.x, home.x / Fixtures.size.width, accuracy: 0.02)
    }

    /// Her marker is picked once, on one day's screenshot, then used every day. A later day matches it less
    /// exactly. She must still be counted while she sits at home, not only once she moves.
    func testMarkerPickedOnAnotherDayStillFindsHerAtHome() async throws {
        let home = CGPoint(x: 600, y: 300), street = CGPoint(x: 1000, y: 750)
        let otherDay = try screenshots([Fixtures.screenshot(marker: home, face: UIColor(red: 0.75, green: 0.42, blue: 0.05, alpha: 1))], in: "heatmap-other-day")
        let template = try await calibrate(on: otherDay[0], tapAt: home)
        let plan: [CGPoint?] = Array(repeating: home, count: 9) + Array(repeating: street, count: 4) + [nil, nil, nil]
        let shots = try screenshots(plan.map { Fixtures.screenshot(marker: $0) }, in: "heatmap-at-home")
        let heatmap = try await HeatmapBuilder.build(from: shots, template: template) { _ in }
        XCTAssertEqual(heatmap.found, 13, "the morning at home counts, as well as the street")
        XCTAssertEqual(heatmap.busiestSpot.x, home.x / Fixtures.size.width, accuracy: 0.02)
    }

    func testTappingAPlainSpotIsRefused() async throws {
        let folder = try Fixtures.makeTemporaryFolder("heatmap-plain")
        let screenshot = try Fixtures.write(Fixtures.screenshot(marker: CGPoint(x: 600, y: 300)), to: folder.appending(path: "a.jpg"), created: .now)
        let image = try XCTUnwrap(UIImage(contentsOfFile: screenshot.url.path))
        do {
            // An empty square of map between roads, nowhere near her marker.
            _ = try await HeatmapBuilder.makeTemplate(from: image, tappedAt: CGPoint(x: 450 / Fixtures.size.width, y: 250 / Fixtures.size.height))
            XCTFail("a tap on plain map should be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too plain"), "unexpected error: \(error.localizedDescription)")
        }
    }

    func testUsesTheLatestReadableScreenshotAsTheBackground() async throws {
        let folder = try Fixtures.makeTemporaryFolder("heatmap-readable")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let good = try Fixtures.write(Fixtures.screenshot(marker: CGPoint(x: 600, y: 300)), to: folder.appending(path: "good.jpg"), created: start)
        let badURL = folder.appending(path: "bad.jpg")
        try Data("not an image".utf8).write(to: badURL)
        let bad = Screenshot(url: badURL, date: start + 300, bytes: 12)

        let skippingTheBadOne = await HeatmapBuilder.lastReadableImage(in: [good, bad])
        let noneReadable = await HeatmapBuilder.lastReadableImage(in: [bad])
        XCTAssertNotNil(skippingTheBadOne, "an unreadable last file is skipped")
        XCTAssertNil(noneReadable)
    }
}
