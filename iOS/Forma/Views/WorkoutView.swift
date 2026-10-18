import SwiftUI
import UIKit

struct WorkoutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: WorkoutStore
    @EnvironmentObject private var auth: AuthService
    @StateObject private var camera = CameraCounter()
    @AppStorage("voiceEnabled") private var voiceEnabled = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @State private var manual = false
    @State private var started = false
    @State private var paused = false
    @State private var needsCalibration = false
    @State private var manualCount = 0
    @State private var startDate = Date()
    @State private var lastTap = Date.distantPast
    @State private var workoutID = UUID()
    @State private var ownerID: UUID?
    @State private var summary: WorkoutRecord?
    @State private var showExit = false
    private var count: Int { manual ? manualCount : camera.count }

    var body: some View {
        GeometryReader { geometry in
            let horizontal = geometry.size.width >= 680 && geometry.size.width > geometry.size.height
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if let result = summary {
                        summaryContent(result)
                    } else if horizontal {
                        HStack(spacing: 44) {
                            readout.frame(maxWidth: .infinity)
                            VStack(spacing: 24) {
                                modeSelector
                                instructions
                                controls
                            }.frame(maxWidth: 390)
                        }.frame(maxHeight: .infinity)
                    } else {
                        modeSelector
                        Spacer(minLength: 0)
                        readout
                        instructions
                        Spacer(minLength: 0)
                        controls
                    }
                }
                .frame(maxWidth: horizontal ? 980 : 560)
                .frame(minHeight: max(0, geometry.size.height - 52))
                .padding(26)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: geometry.size, initial: true) { _, size in camera.updateViewportSize(size) }
        }
        .background(Color.canvas)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; camera.requestAndStart() }
        .onDisappear { camera.stop(); SpeechService.shared.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: camera.count) { _, _ in countChanged() }
        .onChange(of: scenePhase) { _, value in
            if value != .active {
                if started && !paused { togglePause() }
                camera.stop()
            } else if !manual && summary == nil { camera.requestAndStart() }
        }
        .onChange(of: camera.status) { _, value in
            if started && (value == .failed || value == .cameraUnavailable) { paused = true; SpeechService.shared.stop() }
        }
        .onChange(of: camera.geometryRevision) { _, _ in
            guard !manual, started, summary == nil else { return }
            paused = true
            needsCalibration = true
            SpeechService.shared.stop()
            saveDraft()
        }
        .confirmationDialog(L.text("save_before_exit"), isPresented: $showExit, titleVisibility: .visible) {
            Button(L.text("save_workout")) { finish() }
            Button(L.text("discard"), role: .destructive) { store.clearDraft(); dismiss() }
        }
    }

    private var header: some View {
        HStack {
            Button { if started && count > 0 { showExit = true } else { dismiss() } } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44).background(Color.panel, in: Circle())
            }.accessibilityLabel(L.text("close"))
            Spacer()
            Text(L.text(started ? "workout" : "prepare")).font(AppFont.text(13, weight: .medium))
            Spacer()
            Button { voiceEnabled.toggle() } label: {
                Image(systemName: voiceEnabled ? "speaker.wave.2" : "speaker.slash").frame(width: 44, height: 44).background(Color.panel, in: Circle())
            }.accessibilityLabel(L.text("voice"))
        }.foregroundStyle(.primary)
    }

    @ViewBuilder private var modeSelector: some View {
        if !started {
            Picker(L.text("count_mode"), selection: $manual) {
                Text(L.text("camera_mode")).tag(false)
                Text(L.text("touch_mode")).tag(true)
            }.pickerStyle(.segmented).onChange(of: manual) { _, value in
                if value { camera.stop() } else { camera.requestAndStart() }
            }
        }
    }

    private var readout: some View {
        VStack(spacing: 10) {
            if !manual {
                CameraPreview(counter: camera).frame(width: 116, height: 116).clipShape(Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(camera.faceVisible ? 0.7 : 0.15), lineWidth: 2))
                    .accessibilityLabel(L.text(camera.faceVisible ? "face_found" : "find_face"))
            } else {
                Image(systemName: "hand.tap").font(.system(size: 48, weight: .ultraLight)).frame(height: 100)
            }
            if started {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(startDate)))
                        .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Button { registerTap() } label: {
                Text("\(count)")
                    .font(AppFont.numeric(128)).monospacedDigit().lineLimit(1)
                    .contentTransition(.identity)
                    .minimumScaleFactor(0.25).frame(maxWidth: .infinity).frame(height: 164).clipped()
                    .foregroundStyle(count > 0 ? AccentChoice.current.color : Color.primary)
            }.buttonStyle(.plain).disabled(!manual || !started || paused)
                .transaction { $0.animation = nil }
                .accessibilityLabel(L.format("rep_count", count)).accessibilityIdentifier("rep_counter")
        }
    }

    private var instructions: some View {
        VStack(spacing: 14) {
            Text(instruction).font(AppFont.text(16, weight: .medium)).multilineTextAlignment(.center).frame(minHeight: 48)
            if !started {
                Text(L.text(manual ? "touch_help" : "camera_help"))
                    .font(AppFont.text(13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 16) {
            if started {
                if needsCalibration && !manual {
                    StatusNote(text: L.text("orientation_changed"))
                    if !camera.isCalibrated {
                        Button(L.text("calibrate")) { camera.beginCalibration() }.buttonStyle(FilledButton())
                            .disabled(camera.status == .calibrating || camera.status == .idle || camera.status == .requestingPermission)
                    }
                }
                if !manual && !camera.faceVisible && !paused { StatusNote(text: L.text("tracking_lost")) }
                if !manual && (camera.status == .failed || camera.status == .cameraUnavailable) {
                    StatusNote(text: L.text("camera_interrupted"))
                    Button(L.text("retry_camera")) { camera.requestAndStart() }.font(.subheadline)
                }
                HStack(spacing: 12) {
                    Button { togglePause() } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill").frame(width: 64, height: 60).background(Color.panel, in: Capsule())
                    }.accessibilityLabel(L.text(paused ? "resume" : "pause"))
                        .disabled(!manual && paused && !camera.canStartWorkout)
                    Button(L.text("finish")) { finish() }.buttonStyle(FilledButton()).accessibilityIdentifier("finish_workout")
                }
            } else if manual || camera.canStartWorkout {
                Button(L.text("begin")) { begin() }.buttonStyle(FilledButton()).accessibilityIdentifier("begin_workout")
                if !manual { Button(L.text("recalibrate")) { camera.beginCalibration() }.font(.footnote) }
            } else if camera.status == .permissionDenied {
                Button(L.text("open_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(FilledButton())
            } else {
                Button(L.text("calibrate")) { if camera.status == .failed { camera.requestAndStart() }; camera.beginCalibration() }
                    .buttonStyle(FilledButton()).disabled(camera.status != .cameraReady && camera.status != .ready && camera.status != .failed)
            }
            Text(L.text("workout_footer")).font(AppFont.text(10)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
    }

    private func summaryContent(_ result: WorkoutRecord) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Image(systemName: "checkmark.circle").font(.system(size: 50, weight: .ultraLight)).foregroundStyle(AccentChoice.current.color)
            Text(L.text("well_done")).font(AppFont.text(30, weight: .semibold))
            Text("\(result.repetitions)").font(AppFont.numeric(112)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.3)
            Text(L.text("pushups_saved")).foregroundStyle(.secondary)
            if let error = store.storageError { StatusNote(text: error) }
            if let error = model.healthError { StatusNote(text: error) }
            Spacer(minLength: 20)
            Button(L.text("done")) { dismiss() }.buttonStyle(FilledButton()).accessibilityIdentifier("workout_done")
        }
    }

    private var instruction: String {
        if started && !needsCalibration { return L.text(paused ? "paused" : manual ? "tap_to_count" : "keep_going") }
        if manual { return L.text("touch_ready") }
        switch camera.calibration {
        case .upperCountdown(let n): return L.format("upper_countdown", n)
        case .captureUpper: return L.text("hold_upper")
        case .lowerCountdown(let n): return L.format("lower_countdown", n)
        case .captureLower: return L.text("hold_lower")
        case .ready: return L.text("calibrated")
        case .failed: return L.text("calibration_failed")
        case .idle:
            if camera.status == .permissionDenied { return L.text("camera_denied") }
            if camera.status == .cameraUnavailable { return L.text("camera_unavailable") }
            return L.text("position_phone")
        }
    }

    private func begin() {
        guard manual || camera.canStartWorkout else { return }
        started = true; startDate = .now; lastTap = startDate; ownerID = auth.session?.userID
        if !manual { camera.startWorkout() }
        saveDraft()
    }

    private func registerTap() {
        guard manual, started, !paused, Date().timeIntervalSince(lastTap) >= 0.5 else { return }
        lastTap = .now; manualCount += 1; countChanged()
    }

    private func countChanged() {
        guard started, summary == nil else { return }
        if voiceEnabled { SpeechService.shared.speak(count: count, languageCode: L.language) }
        if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        saveDraft()
        if count >= 600 { finish() }
    }

    private func saveDraft() {
        store.updateDraft(WorkoutDraft(id: workoutID, startedAt: startDate, updatedAt: .now, repetitions: count, detectionMode: manual ? "touch" : "camera", ownerID: ownerID))
    }

    private func togglePause() {
        paused.toggle()
        if !manual { if paused { camera.pauseWorkout() } else { camera.startWorkout(); needsCalibration = false } }
        if paused { SpeechService.shared.stop() }
    }

    private func finish() {
        guard count > 0 else { store.clearDraft(); dismiss(); return }
        let item = WorkoutRecord(id: workoutID, startedAt: startDate, endedAt: .now, repetitions: count, detectionMode: manual ? "touch" : "camera", ownerID: ownerID)
        summary = item; camera.stop(); SpeechService.shared.stop(); store.save(item)
        Task { await model.synchronize() }
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
