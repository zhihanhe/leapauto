import XCTest

final class LeapAutoUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testConnectionDiagnosticsAreReachableAndReadOnlyInDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        let link = app.buttons["settings.connection"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["车辆连接与能力"].waitForExistence(timeout: 5))
        let page = app.scrollViews["screen.connection"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let heading = page.descendants(matching: .any)["connection.summary.title"].firstMatch
        XCTAssertTrue(heading.exists)
        XCTAssertTrue(heading.label.contains("连接状态"))
        // MetricRow combines its title/value for VoiceOver, so verify the
        // semantic row rather than assuming the value is a separate text node.
        let source = page.descendants(matching: .any)["connection.source"].firstMatch
        XCTAssertTrue(source.exists)
        XCTAssertTrue(source.label.contains("离线演示"))
        for _ in 0..<6 where !app.buttons["connection.inspect"].isHittable { page.swipeUp() }
        XCTAssertTrue(app.buttons["connection.inspect"].exists)
        XCTAssertFalse(app.buttons["connection.inspect"].isEnabled)
    }

    @MainActor
    func testOfflineDemoAndCancelControl() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.otherElements["vehicle.home"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !app.buttons["control.unlock"].isHittable { app.swipeUp() }
        app.buttons["control.unlock"].tap()
        XCTAssertTrue(app.buttons["control.cancel"].waitForExistence(timeout: 2))
        app.buttons["control.cancel"].tap()
        XCTAssertFalse(app.buttons["control.confirm"].exists)
        app.buttons["control.unlock"].tap()
        XCTAssertTrue(app.secureTextFields["control.pin"].waitForExistence(timeout: 2))
        app.buttons["control.cancel"].tap()
    }
}
