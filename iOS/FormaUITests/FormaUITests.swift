import XCTest

final class FormaUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testGuestWorkoutCanBeSavedAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "dark"]
        app.launchEnvironment["FORMA_RESET_DATA"] = "1"
        app.launch()
        let start = app.buttons["start_workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        snapshot("home-dark")
        start.tap()
        let manual = app.segmentedControls.buttons["Касания"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        manual.tap()
        app.buttons["begin_workout"].tap()
        let counter = app.buttons["rep_counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.65)
            counter.tap()
        }
        snapshot("workout-dark")
        app.buttons["finish_workout"].tap()
        XCTAssertTrue(app.buttons["workout_done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3"].exists)
        app.buttons["workout_done"].tap()
        app.tabBars.buttons["История"].tap()
        XCTAssertTrue(app.staticTexts["3"].firstMatch.waitForExistence(timeout: 5))
        snapshot("history-dark")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "FORMA_RESET_DATA")
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        app.tabBars.buttons["История"].tap()
        XCTAssertTrue(app.staticTexts["3"].firstMatch.waitForExistence(timeout: 5))
    }

    func testThemesAndLanguages() {
        let app = XCUIApplication()
        for (language, theme, title, name) in [
            ("ru", "light", "Настройки", "settings-light"),
            ("en", "dark", "Settings", "settings-english"),
            ("zh-Hans", "light", "设置", "settings-chinese")
        ] {
            app.launchArguments = ["-onboarded", "YES", "-language", language, "-theme", theme]
            app.launchEnvironment["FORMA_SCREEN"] = "3"
            app.launch()
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10))
            snapshot(name)
            app.terminate()
        }
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
