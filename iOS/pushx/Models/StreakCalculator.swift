import Foundation

struct StreakStatus: Equatable {
    let currentDays: Int
    let longestDays: Int
    let todayRepetitions: Int

    var todayQualified: Bool { todayRepetitions >= StreakCalculator.dailyMinimum }
}

enum StreakCalculator {
    static let dailyMinimum = 5

    static func calculate(records: [WorkoutRecord], calendar: Calendar, now: Date) -> StreakStatus {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            return StreakStatus(currentDays: 0, longestDays: 0, todayRepetitions: 0)
        }
        let today = calendar.startOfDay(for: now)
        let totals = dailyTotals(records: records, calendar: calendar, now: now)
        let qualifiedDays = Set(totals.filter { $0.value >= dailyMinimum }.map(\.key))
        let todayRepetitions = totals[today, default: 0]
        var cursor = qualifiedDays.contains(today) ? today : adjacentDay(to: today, offset: -1, calendar: calendar)
        var currentDays = 0
        while let day = cursor, qualifiedDays.contains(day) {
            currentDays += 1
            cursor = adjacentDay(to: day, offset: -1, calendar: calendar)
        }

        var longestDays = 0
        var run = 0
        var previous: Date?
        for day in qualifiedDays.sorted() {
            run = previous.flatMap { adjacentDay(to: $0, offset: 1, calendar: calendar) } == day ? run + 1 : 1
            longestDays = max(longestDays, run)
            previous = day
        }
        return StreakStatus(currentDays: currentDays, longestDays: longestDays, todayRepetitions: todayRepetitions)
    }

    static func dailyTotals(records: [WorkoutRecord], calendar: Calendar, now: Date) -> [Date: Int] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return [:] }
        var totals: [Date: Int] = [:]
        for record in records where record.repetitions > 0 && record.endedAt <= now
            && record.endedAt.timeIntervalSinceReferenceDate.isFinite {
            let day = calendar.startOfDay(for: record.endedAt)
            let sum = totals[day, default: 0].addingReportingOverflow(record.repetitions)
            totals[day] = sum.overflow ? .max : sum.partialValue
        }
        return totals
    }

    private static func adjacentDay(to day: Date, offset: Int, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: offset, to: day).map { calendar.startOfDay(for: $0) }
    }
}
