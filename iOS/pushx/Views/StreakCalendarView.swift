import SwiftUI

struct StreakCalendarView: View {
    let records: [WorkoutRecord]
    @State private var displayedMonth: DateComponents?
    @State private var selectedDay: Date?

    private var calendar: Calendar {
        var result = Calendar.autoupdatingCurrent
        result.locale = Locale(identifier: L.language)
        return result
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let now = max(timeline.date, Date.now)
            let today = calendar.startOfDay(for: now)
            let totals = StreakCalculator.dailyTotals(records: records, calendar: calendar, now: now)
            let streak = StreakCalculator.calculate(records: records, calendar: calendar, now: now)
            let currentMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
            let month = min(displayedMonth.flatMap { calendar.date(from: $0) } ?? currentMonth, currentMonth)
            let selection = min(selectedDay.map { calendar.startOfDay(for: $0) } ?? today, today)

            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        streakMetric("streak_current", value: streak.currentDays, flame: true)
                        streakMetric("streak_longest", value: streak.longestDays)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        streakMetric("streak_current", value: streak.currentDays, flame: true)
                        streakMetric("streak_longest", value: streak.longestDays)
                    }
                }
                Text(L.text("streak_calendar_rule"))
                    .font(AppFont.text(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                monthHeader(month, selection: selection, today: today, canGoForward: month < currentMonth)
                calendarGrid(month: month, today: today, selection: selection, totals: totals)
                Divider()
                dayDetail(selection, today: today, repetitions: totals[selection, default: 0])
            }
            .padding(18).background(Color.panel, in: RoundedRectangle(cornerRadius: 26))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("streak_calendar")
        }
    }

    private func streakMetric(_ key: String, value: Int, flame: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if flame {
                    Image(systemName: "flame.fill").font(.system(size: 18))
                        .foregroundStyle(value > 0 ? Color.accentColor : Color.secondary)
                }
                Text("\(value)").font(AppFont.numeric(30)).lineLimit(1).minimumScaleFactor(0.5)
            }
            Text(L.text(key)).font(AppFont.text(12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func monthHeader(_ month: Date, selection: Date, today: Date, canGoForward: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                changeMonth(by: -1, from: month, selection: selection, today: today)
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.accessibilityLabel(L.text("streak_calendar_previous"))
                .accessibilityIdentifier("streak_previous_month")
            Text(formatted(month, template: "LLLL yyyy"))
                .font(AppFont.text(16, weight: .medium)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button { changeMonth(by: 1, from: month, selection: selection, today: today) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }.disabled(!canGoForward).accessibilityLabel(L.text("streak_calendar_next"))
                .accessibilityIdentifier("streak_next_month")
        }.buttonStyle(.plain)
    }

    private func calendarGrid(month: Date, today: Date, selection: Date, totals: [Date: Int]) -> some View {
        let days = calendar.range(of: .day, in: .month, for: month) ?? 1..<1
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 7), spacing: 7) {
            ForEach(0..<7, id: \.self) { index in
                let weekday = (calendar.firstWeekday - 1 + index) % 7
                Text(symbols[weekday]).font(AppFont.text(10, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 22).accessibilityHidden(true)
            }
            ForEach(0..<leading, id: \.self) { _ in
                Color.clear.frame(height: 44).accessibilityHidden(true)
            }
            ForEach(Array(days), id: \.self) { day in
                if let date = calendar.date(byAdding: .day, value: day - 1, to: month) {
                    dayButton(date, today: today, selection: selection, repetitions: totals[calendar.startOfDay(for: date), default: 0])
                }
            }
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func dayButton(_ day: Date, today: Date, selection: Date, repetitions: Int) -> some View {
        let day = calendar.startOfDay(for: day)
        let future = day > today
        let qualified = repetitions >= StreakCalculator.dailyMinimum
        let isToday = day == today
        let selected = day == selection
        let status = statusKey(day: day, today: today, repetitions: repetitions)
        return Button { selectedDay = day } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))").font(AppFont.numeric(15))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Group {
                    if qualified { Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)) }
                    else if repetitions > 0 { Circle().frame(width: 4, height: 4) }
                    else { Color.clear.frame(width: 4, height: 4) }
                }.frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(qualified ? Color.canvas : future ? Color.secondary.opacity(0.35) : Color.primary)
            .background(qualified ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? Color.primary : isToday ? Color.accentColor : Color.clear, lineWidth: selected ? 2 : 1)
            }
        }.buttonStyle(.plain).disabled(future)
            .accessibilityLabel(formatted(day, template: "EEEE d MMMM yyyy"))
            .accessibilityValue(L.format("streak_calendar_day_accessibility", repetitions, L.text(status)))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier(dayIdentifier(day))
    }

    private func dayDetail(_ day: Date, today: Date, repetitions: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(formatted(day, template: "d MMMM yyyy"))
                .font(AppFont.text(14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(L.format("streak_calendar_total", repetitions)).font(AppFont.text(15))
                .accessibilityIdentifier("streak_selected_total")
            Text(L.text(statusKey(day: day, today: today, repetitions: repetitions)))
                .font(AppFont.text(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("streak_calendar_detail")
    }

    private func statusKey(day: Date, today: Date, repetitions: Int) -> String {
        if day > today { return "streak_calendar_future" }
        if repetitions >= StreakCalculator.dailyMinimum { return "streak_calendar_complete" }
        return day == today ? "streak_calendar_progress" : "streak_calendar_missed"
    }

    private func changeMonth(by offset: Int, from month: Date, selection: Date, today: Date) {
        guard let target = calendar.date(byAdding: .month, value: offset, to: month),
              target <= today,
              let days = calendar.range(of: .day, in: .month, for: target) else { return }
        let ordinal = min(calendar.component(.day, from: selection), days.count)
        guard let day = calendar.date(byAdding: .day, value: ordinal - 1, to: target) else { return }
        displayedMonth = calendar.dateComponents([.era, .year, .month], from: target)
        selectedDay = min(calendar.startOfDay(for: day), today)
    }

    private func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.language)
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func dayIdentifier(_ day: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "streak_day_%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
