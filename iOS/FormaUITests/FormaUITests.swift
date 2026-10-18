import XCTest

final class FormaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    func testFirstLaunchRequiresAppleSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["apple_sign_in"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["start_workout"].exists)
        snapshot("sign-in-dark")
    }

    func testGoalAndAccentCanBeChanged() {
        let app = XCUIApplication()
        app.launchEnvironment["UPRA_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["FORMA_SCREEN"] = "3"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "dark"]
        app.launch()
        let blue = app.buttons["accent_blue"]
        XCTAssertTrue(blue.waitForExistence(timeout: 15))
        blue.tap()
        XCTAssertTrue(blue.isSelected)
        revealAndTap(app.buttons["daily_goal_editor"], in: app)
        XCTAssertTrue(app.buttons["goal_preset_200"].waitForExistence(timeout: 5))
        snapshot("goal-dark")
        app.buttons["goal_preset_200"].tap()
        app.buttons["goal_save"].tap()
        XCTAssertTrue(app.buttons["daily_goal_editor"].staticTexts["200"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(blue.waitForExistence(timeout: 15))
        XCTAssertTrue(blue.isSelected)
        XCTAssertTrue(app.buttons["daily_goal_editor"].staticTexts["200"].exists)
        app.buttons["accent_violet"].tap()
    }

    func testLocalPreviewWorkoutCanBeSavedAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["UPRA_LOCAL_PREVIEW"] = "1"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "dark"]
        app.launchEnvironment["FORMA_RESET_DATA"] = "1"
        app.launch()
        let start = app.buttons["start_workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        snapshot("home-dark")
        revealAndTap(start, in: app)
        let manual = app.segmentedControls.buttons["Касания"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        manual.tap()
        revealAndTap(app.buttons["begin_workout"], in: app)
        let counter = app.buttons["rep_counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.65)
            counter.tap()
        }
        snapshot("workout-dark")
        revealAndTap(app.buttons["finish_workout"], in: app)
        XCTAssertTrue(app.buttons["workout_done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3"].exists)
        app.buttons["workout_done"].tap()
        app.buttons["История"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["3"].firstMatch.waitForExistence(timeout: 5))
        snapshot("history-dark")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "FORMA_RESET_DATA")
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        app.buttons["История"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["3"].firstMatch.waitForExistence(timeout: 5))
    }

    func testThemesAndLanguages() {
        let app = XCUIApplication()
        app.launchEnvironment["UPRA_LOCAL_PREVIEW"] = "1"
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

    func testRotationKeepsWorkoutAndControlsReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["UPRA_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["FORMA_RESET_DATA"] = "1"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "light"]
        app.launch()
        let start = app.buttons["start_workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        snapshot("adaptive-home-portrait")
        revealAndTap(start, in: app)
        let manual = app.segmentedControls.buttons["Касания"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        manual.tap()
        revealAndTap(app.buttons["begin_workout"], in: app)
        let counter = app.buttons["rep_counter"]
        Thread.sleep(forTimeInterval: 0.65)
        revealAndTap(counter, in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        wait(for: [landscape], timeout: 10)
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.65)
        revealAndTap(counter, in: app)
        XCTAssertEqual(counter.label, "Отжиманий: 2")
        Thread.sleep(forTimeInterval: 0.4)
        snapshot("adaptive-workout-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "Отжиманий: 2")
        revealAndTap(app.buttons["finish_workout"], in: app)
        XCTAssertTrue(app.buttons["workout_done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2"].exists)
    }

    func testLargestTextKeepsPrimaryActionReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["UPRA_LOCAL_PREVIEW"] = "1"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "light",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let start = app.buttons["start_workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        revealAndTap(start, in: app)
        let manual = app.segmentedControls.buttons["Касания"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        manual.tap()
        revealAndTap(app.buttons["begin_workout"], in: app)
        XCTAssertTrue(app.buttons["rep_counter"].waitForExistence(timeout: 5))
        snapshot("largest-text-workout")
    }

    private func revealAndTap(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
