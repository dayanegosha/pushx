import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("language") private var language = "system"
    @State private var selection = DevelopmentLaunch.tab
    var body: some View {
        if !onboarded || (!DevelopmentLaunch.allowLocalSession && auth.session == nil) {
            WelcomeView { onboarded = true }
        } else {
            TabView(selection: $selection) {
                HomeView(onStreakTap: { selection = 1 }).tabItem { Label(L.text("train"), systemImage: "circle.circle") }.tag(0)
                HistoryView().tabItem { Label(L.text("statistics"), systemImage: "chart.xyaxis.line") }.tag(1)
                FriendsView().tabItem { Label(L.text("friends"), systemImage: "person.2") }.tag(2)
                SettingsView().tabItem { Label(L.text("settings"), systemImage: "slider.horizontal.3") }.tag(3)
            }.environment(\.locale, Locale(identifier: AppLanguage(rawValue: language)?.code ?? "en"))
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var auth: AuthService
    var complete: () -> Void
    @State private var privacy = false
    var body: some View {
        ScrollView {
            AdaptiveContent(maxWidth: 560) {
            VStack(alignment: .leading, spacing: 24) {
                Brand().padding(.top, 20)
                PushMark().stroke(Color.ink, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .frame(width: 80, height: 80).frame(maxWidth: .infinity).padding(.vertical, 16)
                Text(L.text("welcome_title")).font(AppFont.text(36, weight: .semibold))
                Text(L.text("welcome_body")).font(AppFont.text(14)).foregroundStyle(.secondary).lineSpacing(4)
                AppleLoginButton().frame(maxWidth: 420).frame(maxWidth: .infinity)
                if auth.isBusy { ProgressView().frame(maxWidth: .infinity) }
                if let error = auth.errorMessage { StatusNote(text: error) }
                if !AppConfiguration.isBackendConfigured { StatusNote(text: L.text("sign_in_unavailable")) }
                Text(L.text("free_forever")).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Button(L.text("privacy")) { privacy = true }.font(.footnote).frame(maxWidth: .infinity)
                InfoCard(icon: "face.dashed", title: L.text("on_device"), detail: L.text("on_device_body"))
                InfoCard(icon: "heart", title: "Apple Health", detail: L.text("health_intro"))
            }
            }
        }.background(Color.canvas)
            .interactiveDismissDisabled()
            .sheet(isPresented: $privacy) { PrivacyView().adaptiveSheet() }
            .onChange(of: auth.isBusy) { _, busy in if !busy, auth.session != nil { complete() } }
            .onAppear { if auth.session != nil && !auth.isBusy { complete() } }
    }
}

struct HomeView: View {
    var onStreakTap: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: WorkoutStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var model: AppModel
    @AppStorage("dailyGoal") private var dailyGoal = 50
    @State private var workout = DevelopmentLaunch.workout
    @State private var showStatus = false
    private var records: [WorkoutRecord] { store.visible(for: auth.session?.userID) }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let now = max(timeline.date, Date.now)
                let currentStreak = StreakCalculator.calculate(records: records, calendar: .current, now: now)
                GeometryReader { geometry in
                    let horizontal = geometry.size.width >= 800 || (geometry.size.width >= 640 && geometry.size.width > geometry.size.height)
                    let compact = geometry.size.height < 680
                    VStack(spacing: compact ? 12 : 20) {
                        header(streak: currentStreak, now: now, showDate: geometry.size.width >= 500)
                        if horizontal && dynamicTypeSize.isAccessibilitySize {
                            HStack(spacing: 24) {
                                accessibleReadout(compact: compact, today: currentStreak.todayRepetitions).frame(maxWidth: .infinity)
                                startButton.frame(maxWidth: 390)
                            }.frame(maxHeight: .infinity)
                        } else if horizontal {
                            HStack(spacing: 40) {
                                VStack(alignment: .leading, spacing: 16) {
                                    if !compact && !dynamicTypeSize.isAccessibilitySize { title }
                                    progressRing(diameter: max(120, min(320, geometry.size.height - 160)), today: currentStreak.todayRepetitions)
                                        .frame(maxWidth: .infinity)
                                }.frame(maxWidth: .infinity)
                                VStack(spacing: 24) {
                                    statistics
                                    startButton
                                    placementHint
                                }.frame(maxWidth: 390)
                            }.frame(maxHeight: .infinity)
                        } else {
                            Spacer(minLength: 0)
                            if dynamicTypeSize.isAccessibilitySize {
                                accessibleReadout(compact: compact, today: currentStreak.todayRepetitions)
                            } else {
                                progressRing(diameter: max(120, min(300, geometry.size.width - 64,
                                    geometry.size.height - (compact ? 350 : 450))), today: currentStreak.todayRepetitions)
                            }
                            Spacer(minLength: 0)
                            if !dynamicTypeSize.isAccessibilitySize { statistics }
                            startButton
                            if !compact && !dynamicTypeSize.isAccessibilitySize { placementHint }
                        }
                    }
                        .padding(.horizontal, 20).padding(.vertical, compact ? 16 : 24)
                        .frame(maxWidth: 920, maxHeight: .infinity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.canvas)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .alert(L.text("status"), isPresented: $showStatus) {
            Button(L.text("done"), role: .cancel) {}
        } message: { Text(statusMessages.joined(separator: "\n\n")) }
        .fullScreenCover(isPresented: $workout) { WorkoutView() }
    }

    private func header(streak: StreakStatus, now: Date, showDate: Bool) -> some View {
        HStack(spacing: 12) {
            Brand().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Spacer()
            if !statusMessages.isEmpty {
                Button { showStatus = true } label: { Image(systemName: "exclamationmark.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel(L.text("status")).accessibilityValue(statusMessages.joined(separator: ". "))
            }
            if showDate {
                Text(now.formatted(.dateTime.locale(Locale(identifier: L.language)).day().month(.abbreviated)))
                    .font(AppFont.text(12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            Button(action: onStreakTap) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").font(.system(size: 16))
                        .foregroundStyle(streak.currentDays > 0 ? Color.accentColor : Color.secondary)
                    Text("\(streak.currentDays)").font(AppFont.numeric(18)).lineLimit(1).minimumScaleFactor(0.5)
                }.padding(.horizontal, 10).frame(minHeight: 44)
                    .background(Color.panel, in: Capsule())
            }.buttonStyle(.plain)
                .accessibilityLabel(L.text("streak_title"))
                .accessibilityValue(L.format("streak_accessibility", streak.currentDays, min(streak.todayRepetitions, StreakCalculator.dailyMinimum)))
                .accessibilityIdentifier("home_streak")
                .accessibilityHint(L.text("streak_calendar_open"))
        }
    }

    private var title: some View {
        Text(L.text("home_title")).font(AppFont.text(36, weight: .semibold))
            .lineLimit(2).minimumScaleFactor(0.75).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusMessages: [String] {
        [store.recoveredWorkout ? L.text("workout_recovered") : nil,
         store.storageError, model.healthError, model.syncError].compactMap { $0 }
    }

    private func accessibleReadout(compact: Bool, today: Int) -> some View {
        VStack(spacing: 12) {
            Text(L.text("today")).font(AppFont.text(16, weight: .medium))
                .dynamicTypeSize(...(compact ? DynamicTypeSize.xxxLarge : .accessibility5))
            Text("\(today)").font(AppFont.numeric(compact ? 64 : 88)).lineLimit(1).minimumScaleFactor(0.3)
                .frame(maxWidth: .infinity).frame(height: compact ? 84 : 116)
            Text(L.format("of_goal", dailyGoal)).font(AppFont.text(16)).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
                .dynamicTypeSize(...(compact ? DynamicTypeSize.xxxLarge : .accessibility5))
        }.accessibilityElement(children: .combine)
    }

    private func progressRing(diameter: CGFloat, today: Int) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: 1)
            Circle().trim(from: 0, to: min(1, CGFloat(today) / CGFloat(max(dailyGoal, 1))))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 6) {
                Text(L.text("today").uppercased()).font(AppFont.text(10, weight: .semibold)).tracking(3).foregroundStyle(.secondary)
                Text("\(today)").font(AppFont.numeric(min(88, diameter * 0.34))).lineLimit(1)
                    .minimumScaleFactor(0.3).frame(width: max(60, diameter - 48), height: diameter * 0.44).clipped()
                Text(L.format("of_goal", dailyGoal)).font(AppFont.text(diameter < 180 ? 11 : 13)).foregroundStyle(.secondary)
            }.padding(16).dynamicTypeSize(...DynamicTypeSize.large)
        }.frame(width: diameter, height: diameter).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statistics: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 16) {
                accessibleStat("total", value: records.reduce(0) { $0 + $1.repetitions })
                accessibleStat("sessions", value: records.count)
                accessibleStat("best_set", value: records.map(\.repetitions).max() ?? 0)
            }.padding(20).background(Color.panel, in: RoundedRectangle(cornerRadius: 22))
        } else {
            HStack(spacing: 0) {
            stat("total", value: records.reduce(0) { $0 + $1.repetitions })
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 34)
            stat("sessions", value: records.count)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 34)
            stat("best_set", value: records.map(\.repetitions).max() ?? 0)
            }
        }
    }

    private func accessibleStat(_ key: String, value: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L.text(key)).font(AppFont.text(15)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("\(value)").font(AppFont.text(20, weight: .semibold)).monospacedDigit()
        }
    }

    private var startButton: some View {
        Button { workout = true } label: {
            HStack {
                Text(L.text("start_workout")).fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                    Image(systemName: "arrow.up.right").accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 26)
            .contentShape(Rectangle())
        }.buttonStyle(FilledButton()).accessibilityIdentifier("start_workout")
    }

    private var placementHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "face.dashed").font(.caption)
            Text(L.text("phone_hint")).font(AppFont.text(12)).foregroundStyle(.secondary)
        }
    }

    private func stat(_ key: String, value: Int) -> some View {
        VStack(spacing: 7) {
            Text("\(value)").font(AppFont.text(23, weight: .semibold)).monospacedDigit()
            Text(L.text(key)).font(AppFont.text(10)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}
