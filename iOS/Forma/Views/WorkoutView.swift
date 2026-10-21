import SwiftUI
import UIKit

struct WorkoutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: WorkoutStore
    @EnvironmentObject private var auth: AuthService
    @StateObject private var sensor = FaceDistanceCounter()
    @AppStorage("voiceEnabled") private var voiceEnabled = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @State private var started = false
    @State private var paused = false
    @State private var startDate = Date()
    @State private var workoutID = UUID()
    @State private var ownerID: UUID?
    @State private var summary: WorkoutRecord?
    @State private var showExit = false

    private var count: Int { sensor.count }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if let result = summary {
                        summaryContent(result)
                    } else if (sensor.status == .unavailable || sensor.status == .permissionDenied) && !started {
                        unavailableContent
                    } else {
                        Spacer(minLength: 20)
                        readout
                        instructions
                        Spacer(minLength: 20)
                        controls
                    }
                }
                .frame(maxWidth: 560)
                .frame(minHeight: max(0, geometry.size.height - 48))
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: geometry.size, initial: true) { _, size in sensor.updateViewportSize(size) }
        }
        .background(Color.canvas)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            sensor.prepare()
        }
        .onDisappear {
            sensor.stop()
            SpeechService.shared.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: sensor.count) { _, _ in countChanged() }
        .onChange(of: scenePhase) { _, value in
            if value != .active {
                if started && summary == nil {
                    paused = true
                    sensor.pause()
                    saveDraft()
                } else {
                    sensor.stop()
                }
                SpeechService.shared.stop()
            } else if value == .active && !started && summary == nil {
                sensor.prepare()
            }
        }
        .onChange(of: sensor.status) { _, status in
            if started && summary == nil && (status == .paused || status == .interrupted) {
                paused = true
                SpeechService.shared.stop()
                saveDraft()
            }
        }
        .confirmationDialog(L.text("save_before_exit"), isPresented: $showExit, titleVisibility: .visible) {
            Button(L.text("save_workout")) { finish() }
            Button(L.text("discard"), role: .destructive) { store.clearDraft(); dismiss() }
        }
    }

    private var header: some View {
        HStack {
            Button {
                if started && count > 0 { showExit = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44).background(Color.panel, in: Circle())
            }.accessibilityLabel(L.text("close")).accessibilityIdentifier("close_workout")
            Spacer()
            Text(L.text(started ? "workout" : "prepare")).font(AppFont.text(13, weight: .medium))
            Spacer()
            Button { voiceEnabled.toggle() } label: {
                Image(systemName: voiceEnabled ? "speaker.wave.2" : "speaker.slash")
                    .frame(width: 44, height: 44).background(Color.panel, in: Circle())
            }.accessibilityLabel(L.text("voice"))
        }.foregroundStyle(.primary)
    }

    private var readout: some View {
        VStack(spacing: 24) {
            HStack(spacing: 8) {
                Circle().fill(sensor.faceVisible && !paused ? AccentChoice.current.color : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(L.text(paused ? "paused" : sensor.faceVisible ? "distance_signal_ready" : "distance_signal_search"))
                    .font(AppFont.text(12, weight: .medium)).foregroundStyle(.secondary)
            }
            Text("\(count)")
                .font(AppFont.numeric(152)).lineLimit(1).minimumScaleFactor(0.25)
                .frame(maxWidth: .infinity).frame(height: 190)
                .contentTransition(.identity).transaction { $0.animation = nil }
                .foregroundStyle(count > 0 ? AccentChoice.current.color : Color.primary)
                .accessibilityLabel(L.format("rep_count", count)).accessibilityIdentifier("rep_counter")
            if started {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(startDate)))
                        .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var instructions: some View {
        VStack(spacing: 12) {
            Text(L.text(started ? (paused ? "paused" : !sensor.faceVisible ? "tracking_lost" : !sensor.isCalibrated ? "distance_hold_upper" : "keep_going") : "distance_position"))
                .font(AppFont.text(18, weight: .medium)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !started {
                Text(L.text("distance_help")).font(AppFont.text(14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            if started {
                HStack(spacing: 12) {
                    Button { togglePause() } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .frame(width: 64, height: 60).background(Color.panel, in: Capsule())
                    }.foregroundStyle(.primary).accessibilityLabel(L.text(paused ? "resume" : "pause"))
                    Button(L.text("finish")) { finish() }.buttonStyle(FilledButton()).accessibilityIdentifier("finish_workout")
                }
                if sensor.status == .permissionDenied {
                    Text(L.text("distance_permission_body")).font(AppFont.text(13)).foregroundStyle(.secondary)
                    Button(L.text("open_settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } else if sensor.status == .interrupted {
                Button(L.text("retry_camera")) { sensor.prepare() }.buttonStyle(FilledButton())
            } else {
                Button(L.text("begin")) { begin() }.buttonStyle(FilledButton())
                    .disabled(!sensor.canStart).accessibilityIdentifier("begin_workout")
            }
            Text(L.text("distance_privacy_note")).font(AppFont.text(11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unavailableContent: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 30)
            Image(systemName: "face.dashed").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(L.text(sensor.status == .permissionDenied ? "distance_permission_title" : "distance_unavailable")).font(AppFont.text(26, weight: .semibold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("distance_unavailable")
            Text(L.text(sensor.status == .permissionDenied ? "distance_permission_body" : "distance_unavailable_body")).font(AppFont.text(15)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 30)
            if sensor.status == .permissionDenied {
                Button(L.text("open_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(FilledButton())
            } else {
                Button(L.text("done")) { dismiss() }.buttonStyle(FilledButton())
            }
        }
    }

    private func summaryContent(_ result: WorkoutRecord) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Image(systemName: "checkmark.circle").font(.system(size: 50, weight: .ultraLight)).foregroundStyle(AccentChoice.current.color)
            Text(L.text("well_done")).font(AppFont.text(30, weight: .semibold))
            Text("\(result.repetitions)").font(AppFont.numeric(112)).lineLimit(1).minimumScaleFactor(0.3)
            Text(L.text("pushups_saved")).foregroundStyle(.secondary)
            if let error = store.storageError { StatusNote(text: error) }
            if let error = model.healthError { StatusNote(text: error) }
            Spacer(minLength: 20)
            Button(L.text("done")) { dismiss() }.buttonStyle(FilledButton()).accessibilityIdentifier("workout_done")
        }
    }

    private func begin() {
        guard sensor.canStart else { return }
        sensor.begin()
        started = true
        startDate = .now
        ownerID = auth.session?.userID
        saveDraft()
    }

    private func countChanged() {
        guard started, summary == nil, count > 0 else { return }
        if voiceEnabled { SpeechService.shared.speak(count: count, languageCode: L.language) }
        if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        saveDraft()
        if count >= 600 { finish() }
    }

    private func saveDraft() {
        store.updateDraft(WorkoutDraft(id: workoutID, startedAt: startDate, updatedAt: .now, repetitions: count,
                                       detectionMode: "camera", ownerID: ownerID))
    }

    private func togglePause() {
        if paused {
            guard sensor.resume() else { return }
            paused = false
        } else {
            paused = true
            sensor.pause()
            SpeechService.shared.stop()
            saveDraft()
        }
    }

    private func finish() {
        guard count > 0 else { store.clearDraft(); dismiss(); return }
        let item = WorkoutRecord(id: workoutID, startedAt: startDate, endedAt: .now, repetitions: count,
                                 detectionMode: "camera", ownerID: ownerID)
        summary = item
        sensor.stop()
        SpeechService.shared.stop()
        store.save(item)
        Task { await model.synchronize() }
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
