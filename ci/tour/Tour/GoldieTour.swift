import XCTest

/// Taps through the screens a person would use and saves a screenshot of each.
/// Runs against the Goldie folder ci/smoke.sh seeded (3 days, with the 2 finished days already animated).
final class GoldieTour: XCTestCase {
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOUR_OUTPUT"] ?? NSTemporaryDirectory())

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: output.appending(path: "\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(labelStartingWith text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    func testTour() throws {
        let app = XCUIApplication()
        app.launch()

        // A finished day with its animation: player, frame buttons, speed slider, Rebuild and More.
        let yesterday = element(labelStartingWith: "Yesterday", in: app)
        XCTAssertTrue(yesterday.waitForExistence(timeout: 60), "the day list should show Yesterday")
        yesterday.tap()
        XCTAssertTrue(app.buttons["Rebuild"].waitForExistence(timeout: 60), "Yesterday should already have an animation")
        sleep(4)
        shot("4-day-with-animation")

        // The animation is short, so it has played to its last frame (7:55 AM). Step back two: 7:45 AM.
        let before = XCUIScreen.main.screenshot().pngRepresentation
        let previousFrame = app.buttons["Previous frame"]
        XCTAssertTrue(previousFrame.exists)
        previousFrame.tap()
        previousFrame.tap()
        sleep(2)
        XCTAssertNotEqual(XCUIScreen.main.screenshot().pngRepresentation, before, "stepping should change the frame")
        shot("5-stepped-back-two-frames")

        // The More menu with Delete Animation.
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Delete Animation"].waitForExistence(timeout: 5))
        sleep(1)
        shot("6-more-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.12)).tap()  // close the menu
        sleep(1)

        // Time Range: the pickers, then a built custom animation.
        app.buttons["Time Range"].tap()
        let build = app.buttons["Build"]
        XCTAssertTrue(build.waitForExistence(timeout: 10), "the Custom Animation screen should open")
        sleep(2)
        shot("7-time-range")
        build.tap()
        sleep(25)  // 12 screenshots build in a few seconds; leave room for a slow simulator
        shot("8-time-range-built")
    }
}
