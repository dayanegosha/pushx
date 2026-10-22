import XCTest
@testable import Forma

final class StreakTests: XCTestCase {
    func testFiveRepetitionsAreRequiredToQualifyToday() {
        let calendar = calendar()
        let now = date(2026, 10, 22, hour: 18, calendar: calendar)
        let empty = StreakCalculator.calculate(records: [], calendar: calendar, now: now)
        XCTAssertEqual(StreakCalculator.dailyMinimum, 5)
        XCTAssertEqual(empty.currentDays, 0)
        XCTAssertEqual(empty.longestDays, 0)
        XCTAssertEqual(empty.todayRepetitions, 0)
        XCTAssertFalse(empty.todayQualified)

        let four = StreakCalculator.calculate(records: [record(endedAt: now, repetitions: 4)], calendar: calendar, now: now)
        XCTAssertEqual(four.currentDays, 0)
        XCTAssertEqual(four.longestDays, 0)
        XCTAssertEqual(four.todayRepetitions, 4)
        XCTAssertFalse(four.todayQualified)

        let five = StreakCalculator.calculate(records: [record(endedAt: now, repetitions: 5)], calendar: calendar, now: now)
        XCTAssertEqual(five.currentDays, 1)
        XCTAssertEqual(five.longestDays, 1)
        XCTAssertEqual(five.todayRepetitions, 5)
        XCTAssertTrue(five.todayQualified)
    }

    func testMultipleWorkoutsCanQualifyOneDayOnlyOnce() {
        let calendar = calendar()
        let now = date(2026, 10, 22, hour: 18, calendar: calendar)
        let records = [record(endedAt: now.addingTimeInterval(-600), repetitions: 2),
                       record(endedAt: now.addingTimeInterval(-300), repetitions: 3),
                       record(endedAt: now, repetitions: 7)]
        let result = StreakCalculator.calculate(records: Array(records.reversed()), calendar: calendar, now: now)
        XCTAssertEqual(result.currentDays, 1)
        XCTAssertEqual(result.longestDays, 1)
        XCTAssertEqual(result.todayRepetitions, 12)
        XCTAssertTrue(result.todayQualified)
    }

    func testMissedDayResetsCurrentStreakAndPreservesHistoricalLongest() {
        let calendar = calendar()
        let now = date(2026, 10, 22, hour: 18, calendar: calendar)
        let records = [16, 17, 18, 20].map { record(endedAt: date(2026, 10, $0, calendar: calendar)) }
        let result = StreakCalculator.calculate(records: records, calendar: calendar, now: now)
        XCTAssertEqual(result.currentDays, 0)
        XCTAssertEqual(result.longestDays, 3)
        XCTAssertEqual(result.todayRepetitions, 0)
        XCTAssertFalse(result.todayQualified)
    }

    func testYesterdayStreakSurvivesUntilMidnightAndTodayCanExtendIt() {
        let calendar = calendar()
        let now = date(2026, 10, 22, hour: 23, minute: 59, calendar: calendar)
        let records = [20, 21].map { record(endedAt: date(2026, 10, $0, calendar: calendar)) }
        let active = StreakCalculator.calculate(records: records, calendar: calendar, now: now)
        XCTAssertEqual(active.currentDays, 2)
        XCTAssertEqual(active.longestDays, 2)
        XCTAssertFalse(active.todayQualified)

        let midnight = date(2026, 10, 23, hour: 0, calendar: calendar)
        let expired = StreakCalculator.calculate(records: records, calendar: calendar, now: midnight)
        XCTAssertEqual(expired.currentDays, 0)
        XCTAssertEqual(expired.longestDays, 2)

        let extended = StreakCalculator.calculate(
            records: records + [record(endedAt: date(2026, 10, 22, hour: 22, calendar: calendar))],
            calendar: calendar, now: now
        )
        XCTAssertEqual(extended.currentDays, 3)
        XCTAssertEqual(extended.longestDays, 3)
        XCTAssertEqual(extended.todayRepetitions, 5)
        XCTAssertTrue(extended.todayQualified)
    }

    func testFutureAndNonpositiveWorkoutsCannotQualifyToday() {
        let calendar = calendar()
        let now = date(2026, 10, 22, calendar: calendar)
        let records = [
            record(endedAt: date(2026, 10, 21, calendar: calendar)),
            record(endedAt: now.addingTimeInterval(-60), repetitions: 4),
            record(endedAt: now, repetitions: 0),
            record(endedAt: now, repetitions: -20),
            record(endedAt: now.addingTimeInterval(1), repetitions: 5),
            record(endedAt: date(2026, 10, 23, calendar: calendar), repetitions: 100)
        ]
        let result = StreakCalculator.calculate(records: records, calendar: calendar, now: now)
        XCTAssertEqual(result.currentDays, 1)
        XCTAssertEqual(result.longestDays, 1)
        XCTAssertEqual(result.todayRepetitions, 4)
        XCTAssertFalse(result.todayQualified)
    }

    func testLeapDayBelongsToTheConsecutiveStreak() {
        let calendar = calendar("America/New_York")
        let records = [record(endedAt: date(2024, 2, 28, calendar: calendar)),
                       record(endedAt: date(2024, 2, 29, calendar: calendar)),
                       record(endedAt: date(2024, 3, 1, calendar: calendar))]
        let result = StreakCalculator.calculate(records: records, calendar: calendar,
                                                now: date(2024, 3, 1, hour: 18, calendar: calendar))
        XCTAssertEqual(result.currentDays, 3)
        XCTAssertEqual(result.longestDays, 3)
        XCTAssertTrue(result.todayQualified)
    }

    func testSpringAndAutumnClockChangesKeepCalendarDaysConsecutive() {
        let calendar = calendar("America/New_York")
        for start in [date(2026, 3, 7, calendar: calendar), date(2026, 10, 31, calendar: calendar)] {
            let dates = (0..<3).map { calendar.date(byAdding: .day, value: $0, to: start)! }
            let now = calendar.date(byAdding: .hour, value: 6, to: dates[2])!
            let result = StreakCalculator.calculate(records: dates.map { record(endedAt: $0) },
                                                    calendar: calendar, now: now)
            XCTAssertEqual(result.currentDays, 3)
            XCTAssertEqual(result.longestDays, 3)
            XCTAssertTrue(result.todayQualified)
        }
    }

    func testStreaksLongerThanAYearHaveNoArtificialCap() {
        let calendar = calendar()
        let now = date(2026, 10, 22, hour: 18, calendar: calendar)
        let today = date(2026, 10, 22, calendar: calendar)
        let records = (0..<800).map {
            record(endedAt: calendar.date(byAdding: .day, value: -$0, to: today)!)
        }
        let result = StreakCalculator.calculate(records: records, calendar: calendar, now: now)
        XCTAssertEqual(result.currentDays, 800)
        XCTAssertEqual(result.longestDays, 800)
        XCTAssertEqual(result.todayRepetitions, 5)
    }

    func testEndedAtAndExplicitTimezoneDetermineTheMidnightBoundary() {
        let utc = calendar()
        let local = calendar("Europe/Moscow")
        let midnight = date(2026, 10, 21, hour: 21, calendar: utc)
        let now = date(2026, 10, 22, calendar: utc)
        let records = [record(endedAt: midnight.addingTimeInterval(-1)), record(endedAt: midnight)]

        let localResult = StreakCalculator.calculate(records: records, calendar: local, now: now)
        XCTAssertEqual(localResult.currentDays, 2)
        XCTAssertEqual(localResult.longestDays, 2)
        XCTAssertEqual(localResult.todayRepetitions, 5)
        XCTAssertTrue(localResult.todayQualified)

        let utcResult = StreakCalculator.calculate(records: records, calendar: utc, now: now)
        XCTAssertEqual(utcResult.currentDays, 1)
        XCTAssertEqual(utcResult.longestDays, 1)
        XCTAssertEqual(utcResult.todayRepetitions, 0)
        XCTAssertFalse(utcResult.todayQualified)
    }

    func testDailyTotalsIncludePartialDaysAndSumAtTheLocalMidnightBoundary() {
        let utc = calendar()
        let local = calendar("Europe/Moscow")
        let midnight = date(2026, 10, 21, hour: 21, calendar: utc)
        let now = date(2026, 10, 22, calendar: utc)
        let records = [record(endedAt: midnight.addingTimeInterval(-1), repetitions: 2),
                       record(endedAt: midnight, repetitions: 1),
                       record(endedAt: midnight.addingTimeInterval(60), repetitions: 3)]
        let localTotals = StreakCalculator.dailyTotals(records: records, calendar: local, now: now)
        XCTAssertEqual(localTotals, [local.startOfDay(for: midnight.addingTimeInterval(-1)): 2,
                                     local.startOfDay(for: midnight): 4])
        let utcTotals = StreakCalculator.dailyTotals(records: records, calendar: utc, now: now)
        XCTAssertEqual(utcTotals, [utc.startOfDay(for: midnight): 6])
    }

    func testDailyTotalsExcludeFutureNonpositiveAndInvalidWorkouts() {
        let calendar = calendar()
        let now = date(2026, 10, 22, calendar: calendar)
        let records = [record(endedAt: now, repetitions: 3),
                       record(endedAt: now, repetitions: 0),
                       record(endedAt: now, repetitions: -4),
                       record(endedAt: now.addingTimeInterval(1), repetitions: 5),
                       record(endedAt: date(2026, 10, 23, calendar: calendar), repetitions: 10),
                       record(endedAt: Date(timeIntervalSinceReferenceDate: .nan)),
                       record(endedAt: Date(timeIntervalSinceReferenceDate: -.infinity))]
        XCTAssertEqual(StreakCalculator.dailyTotals(records: records, calendar: calendar, now: now),
                       [calendar.startOfDay(for: now): 3])
        XCTAssertTrue(StreakCalculator.dailyTotals(records: records, calendar: calendar,
                                                   now: Date(timeIntervalSinceReferenceDate: .nan)).isEmpty)
    }

    func testDailyTotalsPreserveLongHistoryAndRepetitionsAboveTheQualificationThreshold() {
        let calendar = calendar()
        let now = date(2026, 10, 22, hour: 18, calendar: calendar)
        let today = date(2026, 10, 22, calendar: calendar)
        var records = (0..<800).map {
            record(endedAt: calendar.date(byAdding: .day, value: -$0, to: today)!, repetitions: 100)
        }
        records.append(record(endedAt: today, repetitions: .max))
        let totals = StreakCalculator.dailyTotals(records: records, calendar: calendar, now: now)
        XCTAssertEqual(totals.count, 800)
        XCTAssertEqual(totals[calendar.startOfDay(for: today)], Int.max)
        let oldest = calendar.date(byAdding: .day, value: -799, to: today)!
        XCTAssertEqual(totals[calendar.startOfDay(for: oldest)], 100)
    }

    private func calendar(_ timezone: String = "UTC") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: timezone)!
        return result
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func record(endedAt: Date, repetitions: Int = 5) -> WorkoutRecord {
        WorkoutRecord(id: UUID(), startedAt: endedAt.addingTimeInterval(-60), endedAt: endedAt,
                      repetitions: repetitions, detectionMode: "touch", ownerID: nil)
    }
}
