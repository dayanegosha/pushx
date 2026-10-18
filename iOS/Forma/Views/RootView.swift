import SwiftUI

struct RootView: View {
    @AppStorage("onboarded") private var onboarded = false
    @State private var selection = DevelopmentLaunch.tab
    var body: some View {
        TabView(selection: $selection) {
            HomeView().tabItem { Label(L.text("train"), systemImage: "circle.circle") }.tag(0)
            HistoryView().tabItem { Label(L.text("history"), systemImage: "chart.xyaxis.line") }.tag(1)
            FriendsView().tabItem { Label(L.text("friends"), systemImage: "person.2") }.tag(2)
            SettingsView().tabItem { Label(L.text("settings"), systemImage: "slider.horizontal.3") }.tag(3)
        }
        .tint(.primary)
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            WelcomeView { onboarded = true }
        }
    }
}

struct WelcomeView: View {
    var complete: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Brand().padding(.top, 36)
                Spacer(minLength: 30)
                Image(systemName: "circle.circle").font(.system(size: 100, weight: .ultraLight)).frame(maxWidth: .infinity).padding(30)
                Text(L.text("welcome_title")).font(.system(size: 44, weight: .bold, design: .rounded)).tracking(-2)
                Text(L.text("welcome_body")).foregroundStyle(.secondary).lineSpacing(5)
                InfoCard(icon: "viewfinder", title: L.text("on_device"), detail: L.text("on_device_body"))
                InfoCard(icon: "heart", title: "Apple Health", detail: L.text("health_intro"))
                Button(L.text("lets_go"), action: complete).buttonStyle(FilledButton())
                Text(L.text("free_forever")).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(28)
        }.background(Color.canvas)
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: WorkoutStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var model: AppModel
    @AppStorage("dailyGoal") private var dailyGoal = 50
    @State private var workout = DevelopmentLaunch.workout
    private var records: [WorkoutRecord] { store.visible(for: auth.session?.userID) }
    private var today: Int { records.filter { Calendar.current.isDateInToday($0.endedAt) }.reduce(0) { $0 + $1.repetitions } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    HStack {
                        Brand()
                        Spacer()
                        Text(Date.now.formatted(.dateTime.locale(Locale(identifier: L.language)).day().month(.abbreviated))).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                    PageTitle(eyebrow: L.text("your_pace"), title: L.text("home_title"))
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        Circle().trim(from: 0, to: min(1, CGFloat(today) / CGFloat(max(dailyGoal, 1))))
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 6) {
                            Text(L.text("today").uppercased()).font(.system(size: 10, weight: .semibold)).tracking(3).foregroundStyle(.secondary)
                            Text(String(format: "%02d", today)).font(.system(size: 94, weight: .light, design: .rounded)).monospacedDigit().tracking(-5).minimumScaleFactor(0.5)
                            Text(L.format("of_goal", dailyGoal)).font(.system(size: 13)).foregroundStyle(.secondary)
                        }.padding(32)
                    }.frame(width: 260, height: 260).padding(.vertical, 2)
                    HStack(spacing: 0) {
                        stat("total", value: records.reduce(0) { $0 + $1.repetitions })
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 34)
                        stat("sessions", value: records.count)
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 34)
                        stat("best_set", value: records.map(\.repetitions).max() ?? 0)
                    }
                    Button { workout = true } label: {
                        HStack { Text(L.text("start_workout")); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 26)
                    }.buttonStyle(FilledButton()).accessibilityIdentifier("start_workout")
                    HStack(spacing: 7) {
                        Image(systemName: "iphone").font(.caption)
                        Text(L.text("phone_hint")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if store.recoveredWorkout { StatusNote(text: L.text("workout_recovered")) }
                    if let error = store.storageError { StatusNote(text: error) }
                    if let error = model.healthError { StatusNote(text: error) }
                    if let error = model.syncError { StatusNote(text: error) }
                    InfoCard(icon: "sparkle", title: L.text("small_steps"), detail: L.text("small_steps_body"))
                }.padding(.horizontal, 26).padding(.bottom, 24)
            }.background(Color.canvas)
                .toolbar(.hidden, for: .navigationBar)
                .refreshable { await model.synchronize() }
        }
        .fullScreenCover(isPresented: $workout) { WorkoutView() }
    }
    private func stat(_ key: String, value: Int) -> some View {
        VStack(spacing: 7) {
            Text("\(value)").font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(L.text(key)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }
}
