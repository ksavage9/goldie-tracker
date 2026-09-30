import AVFoundation
import XCTest
@testable import GoldieCore

/// The real VideoBuilder, writing real MP4s with AVFoundation, checked by reading them back.
@MainActor
final class VideoBuilderTests: XCTestCase {
    func testBuildsAPlayableVideoWithOneFramePerScreenshot() async throws {
        let folder = try Fixtures.makeTemporaryFolder("video")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var screenshots: [Screenshot] = []
        for i in 0..<12 {
            let marker = CGPoint(x: 500 + Double(i) * 40, y: 300 + Double(i) * 20)
            screenshots.append(try Fixtures.write(Fixtures.screenshot(marker: marker), to: folder.appending(path: "\(i).jpg"), created: start + Double(i) * 300))
        }
        let output = folder.appending(path: "day.mp4")
        var progress: [Double] = []

        try await VideoBuilder.makeVideo(from: screenshots, to: output) { progress.append($0) }

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 12.0 / 5, accuracy: 0.01, "12 screenshots at 5 per second, the last one shown for a full frame")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1280, height: 958), "scaled to 1280 wide, even height for H.264")

        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(trackOutput)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = trackOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
        }
        XCTAssertEqual(frames, 12)

        XCTAssertEqual(progress.count, 12)
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress, progress.sorted(), "progress only goes forward")

        // The time stamp pill is drawn in the bottom-left corner; the map shows elsewhere.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: 1, timescale: 10)).image
        XCTAssertEqual(frame.width, 1280)
        XCTAssertLessThan(Fixtures.brightness(of: frame, x: 36, y: 890), 0.5, "dark time stamp pill in the bottom-left")
        XCTAssertGreaterThan(Fixtures.brightness(of: frame, x: 640, y: 100), 0.7, "light map background")
    }

    func testMultiDayAnimationsStampTheDateToo() async throws {
        let folder = try Fixtures.makeTemporaryFolder("video-dates")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let screenshots = [
            try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "a.jpg"), created: start),
            try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "b.jpg"), created: start + 86_400),
        ]
        func firstFrame(showsDate: Bool) async throws -> CGImage {
            let output = folder.appending(path: showsDate ? "dates.mp4" : "times.mp4")
            try await VideoBuilder.makeVideo(from: screenshots, to: output, showsDate: showsDate) { _ in }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(value: 1, timescale: 10)).image
        }
        // Just inside the top of the pill, right of where "3:05 PM" ends but inside "Sep 29, 3:05 PM".
        let timeOnly = try await firstFrame(showsDate: false)
        let withDate = try await firstFrame(showsDate: true)
        XCTAssertGreaterThan(Fixtures.brightness(of: timeOnly, x: 350, y: 843), 0.7, "a time alone leaves this spot as map")
        XCTAssertLessThan(Fixtures.brightness(of: withDate, x: 350, y: 843), 0.5, "the wider date-and-time pill covers it")
    }

    func testSkipsUnreadableFilesAndRejectsADayWithNone() async throws {
        let folder = try Fixtures.makeTemporaryFolder("video-bad")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let good1 = try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "a.jpg"), created: start)
        let badURL = folder.appending(path: "b.jpg")
        try Data("not an image".utf8).write(to: badURL)
        let bad = Screenshot(url: badURL, date: start + 300, bytes: 12)
        let good2 = try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "c.jpg"), created: start + 600)

        let output = folder.appending(path: "day.mp4")
        try await VideoBuilder.makeVideo(from: [bad, good1, bad, good2], to: output) { _ in }
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 2.0 / 5, accuracy: 0.01, "only the 2 readable screenshots become frames")

        do {
            try await VideoBuilder.makeVideo(from: [bad, bad], to: folder.appending(path: "none.mp4")) { _ in }
            XCTFail("a day with no readable screenshots should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No readable screenshots for this day.")
        }
    }

    func testCancellingStopsTheBuild() async throws {
        let folder = try Fixtures.makeTemporaryFolder("video-cancel")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var screenshots: [Screenshot] = []
        for i in 0..<40 {
            screenshots.append(try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "\(i).jpg"), created: start + Double(i) * 300))
        }
        let task = Task { @MainActor in
            try await VideoBuilder.makeVideo(from: screenshots, to: folder.appending(path: "day.mp4")) { progress in
                if progress > 0.2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        // Either it notices the cancellation while waiting for the encoder, or it finishes; it must not hang or crash.
        do {
            try await task.value
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
    }
}
