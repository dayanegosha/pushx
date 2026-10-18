import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @AppStorage("onboarded") private var onboarded = false
    @State private var selection = DevelopmentLaunch.tab
    var body: some View {
        if !onboarded || (!DevelopmentLaunch.allowLocalSession && auth.session == nil) {
            WelcomeView { onboarded = true }
        } else {
            TabView(selection: $selection) {
                HomeView().tabItem { Label(L.text("train"), systemImage: "circle.circle") }.tag(0)
                HistoryView().tabItem { Label(L.text("history"), systemImage: "chart.xyaxis.line") }.tag(1)
                FriendsView().tabItem { Label(L.text("friends"), systemImage: "person.2") }.tag(2)
                SettingsView().tabItem { Label(L.text("settings"), systemImage: "slider.horizontal.3") }.tag(3)
            }
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
                UpraMark().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .frame(width: 80, height: 80).frame(maxWidth: .infinity).padding(.vertical, 16)
                Text(L.text("welcome_title")).font(AppFont.text(36, weight: .semibold))
                Text(L.text("welcome_body")).font(AppFont.text(14)).foregroundStyle(.secondary).lineSpacing(4)
                AppleLoginButton().frame(maxWidth: 420).frame(maxWidth: .infinity)
                if auth.isBusy { ProgressView().frame(maxWidth: .infinity) }
                if let error = auth.errorMessage { StatusNote(text: error) }
                if !AppConfiguration.isBackendConfigured { StatusNote(text: L.text("sign_in_unavailable")) }
                Text(L.text("free_forever")).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Button(L.text("privacy")) { privacy = true }.font(.footnote).frame(maxWidth: .infinity)
                InfoCard(icon: "viewfinder", title: L.text("on_device"), detail: L.text("on_device_body"))
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: WorkoutStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var model: AppModel
    @AppStorage("dailyGoal") private var dailyGoal = 50
    @State private var workout = DevelopmentLaunch.workout
    private var records: [WorkoutRecord] { store.visible(for: auth.session?.userID) }
    private var today: Int { records.filter { Calendar.current.isDateInToday($0.endedAt) }.reduce(0) { $0 + $1.repetitions } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    AdaptiveContent(maxWidth: 920) {
                        VStack(spacing: 28) {
                            HStack {
                                Brand()
                                Spacer()
                                Text(Date.now.formatted(.dateTime.locale(Locale(identifier: L.language)).day().month(.abbreviated)))
                                    .font(AppFont.text(12, weight: .medium)).foregroundStyle(.secondary)
                            }
                            PageTitle(title: L.text("home_title"))
                            if geometry.size.width >= 800 && !dynamicTypeSize.isAccessibilitySize {
                                HStack(spacing: 56) {
                                    progressRing(diameter: 320)
                                    VStack(spacing: 32) {
                                        statistics
                                        startButton
                                        placementHint
                                    }.frame(maxWidth: .infinity)
                                }.padding(.vertical, 24)
                            } else {
                                progressRing(diameter: geometry.size.width >= 600 ? 320 : min(260, geometry.size.width - 40))
                                statistics
                                startButton
                                placementHint
                            }
                            if store.recoveredWorkout { StatusNote(text: L.text("workout_recovered")) }
                            if let error = store.storageError { StatusNote(text: error) }
                            if let error = model.healthError { StatusNote(text: error) }
                            if let error = model.syncError { StatusNote(text: error) }
                            InfoCard(icon: "sparkle", title: L.text("small_steps"), detail: L.text("small_steps_body"))
                        }
                    }
                }.background(Color.canvas)
                    .toolbar(.hidden, for: .navigationBar)
                    .refreshable { await model.synchronize() }
            }
        }
        .fullScreenCover(isPresented: $workout) { WorkoutView() }
    }

    private func progressRing(diameter: CGFloat) -> some View {
        VStack(spacing: 16) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(L.text("today")).font(AppFont.text(16, weight: .medium))
            }
            ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: 1)
            Circle().trim(from: 0, to: min(1, CGFloat(today) / CGFloat(max(dailyGoal, 1))))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 6) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(L.text("today").uppercased()).font(AppFont.text(10, weight: .semibold)).tracking(3).foregroundStyle(.secondary)
                }
                Text("\(today)").font(AppFont.numeric(88)).monospacedDigit().lineLimit(1)
                    .minimumScaleFactor(0.3).frame(width: max(80, diameter - 64), height: 116).clipped()
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(L.format("of_goal", dailyGoal)).font(AppFont.text(13)).foregroundStyle(.secondary)
                }
            }.padding(24)
            }.frame(width: diameter, height: diameter)
            if dynamicTypeSize.isAccessibilitySize {
                Text(L.format("of_goal", dailyGoal)).font(AppFont.text(16)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
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
            HStack { Text(L.text("start_workout")); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 26)
        }.buttonStyle(FilledButton()).accessibilityIdentifier("start_workout")
    }

    private var placementHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "viewfinder").font(.caption)
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
