import XCTest
import UIKit

final class PushxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    func testFirstLaunchRequiresAppleSignIn() {
        let app = XCUIApplication()
        for theme in ["dark", "light"] {
            app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", theme]
            app.launch()
            XCTAssertTrue(app.buttons["apple_sign_in"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["start_workout"].exists)
            snapshot("sign-in-" + theme)
            app.terminate()
        }
    }

    func testGoalAndAccentCanBeChanged() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["PUSHX_SCREEN"] = "3"
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

    func testLanguageChangesKeepSettingsOpenAndRefreshTabs() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["PUSHX_SCREEN"] = "3"
        app.launchArguments = ["-onboarded", "YES", "-theme", "dark"]
        app.launch()
        let language = app.buttons["appearance_language"]
        XCTAssertTrue(language.waitForExistence(timeout: 15))
        language.tap()
        app.buttons["English"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(language.isHittable)
        XCTAssertFalse(app.buttons["start_workout"].exists)
        XCTAssertTrue(app.buttons["appearance_theme"].exists)
        snapshot("settings-live-english")
        language.tap()
        app.buttons["简体中文"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["设置"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(language.isHittable)
        XCTAssertFalse(app.buttons["start_workout"].exists)
        snapshot("settings-live-chinese")
        language.tap()
        app.buttons["Русский"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Настройки"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(language.isHittable)
    }

    func testAppearanceMenusFollowAccentAndAccountCardFits() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["PUSHX_SCREEN"] = "3"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "dark"]
        app.launch()
        let blue = app.buttons["accent_blue"]
        XCTAssertTrue(blue.waitForExistence(timeout: 15))
        blue.tap()
        XCTAssertTrue(blue.isSelected)
        XCTAssertTrue(app.buttons["appearance_theme"].isHittable)
        XCTAssertTrue(app.buttons["appearance_language"].isHittable)
        snapshot("settings-accent-blue")
        app.buttons["accent_rose"].tap()
        snapshot("settings-accent-rose")
        let apple = app.buttons["apple_sign_in"]
        for _ in 0..<4 {
            if apple.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(apple.isHittable)
        snapshot("settings-account-card")
    }

    func testHomeCounterFitsWithoutScrolling() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "dark"]
        app.launch()
        let start = app.buttons["start_workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(start.isHittable)
        XCTAssertEqual(app.scrollViews.count, 0)
        let initialFrame = start.frame
        app.swipeUp()
        XCTAssertEqual(start.frame, initialFrame)
        snapshot("home-fixed-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        let isTablet = UIDevice.current.userInterfaceIdiom == .pad
        XCTAssertEqual(app.frame.width > app.frame.height, isTablet)
        XCTAssertTrue(start.isHittable)
        XCTAssertEqual(app.scrollViews.count, 0)
        XCTAssertTrue(app.frame.contains(start.frame))
        snapshot(isTablet ? "home-fixed-landscape" : "home-portrait-locked")
    }

    func testSimulatorCannotCreateManualOrCameraRecordings() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["PUSHX_RESET_DATA"] = "1"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["start_workout"].waitForExistence(timeout: 15))
        app.buttons["start_workout"].tap()
        XCTAssertTrue(app.staticTexts["distance_unavailable"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.segmentedControls.count, 0)
        XCTAssertFalse(app.buttons["rep_counter"].exists)
        XCTAssertFalse(app.buttons["begin_workout"].exists)
        XCTAssertTrue(app.buttons["close_workout"].isHittable)
        snapshot("automatic-counting-unavailable-simulator")
        app.buttons["close_workout"].tap()
        XCTAssertTrue(app.buttons["start_workout"].waitForExistence(timeout: 5))
    }

    func testThemesAndLanguages() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        for (language, theme, title, name) in [
            ("ru", "light", "Настройки", "settings-light"),
            ("en", "dark", "Settings", "settings-english"),
            ("zh-Hans", "light", "设置", "settings-chinese")
        ] {
            app.launchArguments = ["-onboarded", "YES", "-language", language, "-theme", theme]
            app.launchEnvironment["PUSHX_SCREEN"] = "3"
            app.launch()
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10))
            snapshot(name)
            app.terminate()
        }
    }

    func testRotationKeepsWorkoutAndControlsReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["start_workout"].waitForExistence(timeout: 15))
        app.buttons["start_workout"].tap()
        XCTAssertTrue(app.staticTexts["distance_unavailable"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.frame.width > app.frame.height, UIDevice.current.userInterfaceIdiom == .pad)
        XCTAssertTrue(app.buttons["close_workout"].isHittable)
        snapshot("automatic-workout-orientation")
        app.buttons["close_workout"].tap()
        XCTAssertTrue(app.buttons["start_workout"].waitForExistence(timeout: 5))
    }

    func testLargestTextKeepsPrimaryActionReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "light",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let start = app.buttons["start_workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(start.isHittable)
        XCTAssertEqual(app.scrollViews.count, 0)
        XCTAssertTrue(app.frame.contains(start.frame))
        snapshot("largest-text-home")
        start.tap()
        XCTAssertTrue(app.staticTexts["distance_unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["close_workout"].isHittable)
        snapshot("largest-text-workout")
    }

    func testStreakOpensStatisticsAndRemindersStartDisabled() {
        let app = XCUIApplication()
        app.launchEnvironment["PUSHX_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["PUSHX_RESET_DATA"] = "1"
        app.launchArguments = ["-onboarded", "YES", "-language", "ru", "-theme", "dark", "-dailyReminderEnabled", "NO"]
        app.launch()
        let streak = app.buttons["home_streak"]
        XCTAssertTrue(streak.waitForExistence(timeout: 15))
        XCTAssertTrue(streak.isHittable)
        XCTAssertTrue((streak.value as? String)?.contains("0 из 5") == true)
        XCTAssertEqual(app.scrollViews.count, 0)
        streak.tap()
        let calendar = app.descendants(matching: .any)["streak_calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 10))
        if UIDevice.current.userInterfaceIdiom != .pad {
            XCTAssertTrue(app.tabBars.buttons["Статистика"].isSelected)
        }
        XCTAssertEqual(app.alerts.count, 0)
        snapshot("streak-statistics-calendar")
        app.buttons["Настройки"].firstMatch.tap()
        XCTAssertTrue(app.buttons["appearance_theme"].waitForExistence(timeout: 10))
        let reminder = app.switches["reminder_toggle"]
        for _ in 0..<8 {
            if reminder.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        if !reminder.isHittable {
            snapshot("reminder-default-off-diagnostics")
            print(app.debugDescription)
        }
        XCTAssertTrue(reminder.isHittable)
        XCTAssertEqual(reminder.value as? String, "0")
        XCTAssertFalse(app.datePickers["reminder_time"].exists)
        XCTAssertEqual(app.alerts.count, 0)
        snapshot("reminder-default-off")
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
