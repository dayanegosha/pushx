import SwiftUI
import UIKit
import ARKit
import AVFoundation

struct WorkoutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: WorkoutStore
    @EnvironmentObject private var auth: AuthService
    @StateObject private var sensor = FaceDistanceCounter()
    @AppStorage("voiceEnabled") private var voiceEnabled = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("workoutPlacementGuideSeen") private var guideSeen = false
    @State private var started = false
    @State private var paused = false
    @State private var startDate = Date()
    @State private var workoutID = UUID()
    @State private var ownerID: UUID?
    @State private var summary: WorkoutRecord?
    @State private var showExit = false
    @State private var permissionIntro = false
    @State private var placementGuide = false
    @State private var awaitingPermission = false

    private var count: Int { sensor.count }
    private var unavailable: Bool { !started && (sensor.status == .unavailable || sensor.status == .permissionDenied) }

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                GeometryReader { geometry in
                    if summary != nil || permissionIntro || placementGuide || unavailable {
                        ScrollView {
                            VStack(spacing: 24) {
                                if let result = summary {
                                    summaryContent(result)
                                } else if permissionIntro {
                                    introduction(permission: true)
                                } else if placementGuide {
                                    introduction(permission: false)
                                } else {
                                    unavailableContent
                                }
                            }
                            .frame(maxWidth: 620)
                            .frame(minHeight: max(0, geometry.size.height - 40))
                            .padding(.horizontal, 24).padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        counterStage(size: geometry.size)
                    }
                }
                if summary == nil && !permissionIntro && !placementGuide && !unavailable {
                    controls.padding(.horizontal, 24).padding(.vertical, 16)
                        .frame(maxWidth: 620).frame(maxWidth: .infinity)
                }
            }
            .onChange(of: viewport.size, initial: true) { _, size in sensor.updateViewportSize(size) }
        }
        .background {
            Color.canvas.ignoresSafeArea()
            RadialGradient(colors: [AccentChoice.current.color.opacity(0.045), .clear], center: .center,
                           startRadius: 20, endRadius: 420).ignoresSafeArea()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            prepareWorkout()
            beginWhenReady()
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
                } else if !awaitingPermission {
                    sensor.stop()
                }
                SpeechService.shared.stop()
            } else if !started && summary == nil && !permissionIntro && !placementGuide && !awaitingPermission {
                prepareWorkout()
                beginWhenReady()
            }
        }
        .onChange(of: sensor.isPhoneMoving) { _, moving in
            if !moving { beginWhenReady() }
        }
        .onChange(of: sensor.status) { _, status in
            if awaitingPermission && status != .requestingPermission && status != .idle {
                awaitingPermission = false
                if status == .ready && !guideSeen { placementGuide = true }
            }
            if started && summary == nil && (status == .paused || status == .interrupted) {
                paused = true
                SpeechService.shared.stop()
                saveDraft()
            }
            beginWhenReady()
        }
        .confirmationDialog(L.text("save_before_exit"), isPresented: $showExit, titleVisibility: .visible) {
            Button(L.text("save_workout")) { finish() }
            Button(L.text("discard"), role: .destructive) { store.clearDraft(); dismiss() }
        }
    }

    private var header: some View {
        HStack {
            Button {
                if summary == nil && started && count > 0 { showExit = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
                    .frame(width: 44, height: 44).modifier(WorkoutGlass(shape: Circle()))
            }.accessibilityLabel(L.text("close")).accessibilityIdentifier("close_workout")
            Spacer()
            PushMark().stroke(Color.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 32, height: 32).accessibilityHidden(true)
            Spacer()
            Button { voiceEnabled.toggle() } label: {
                Image(systemName: voiceEnabled ? "speaker.wave.2" : "speaker.slash")
                    .font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
                    .modifier(WorkoutGlass(shape: Circle()))
            }.accessibilityLabel(L.text("voice")).accessibilityValue(L.text(voiceEnabled ? "workout_voice_on" : "workout_voice_off"))
        }.foregroundStyle(.primary).buttonStyle(.plain)
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            if sensor.isPhoneMoving && !paused {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.text("workout_phone_moving")).font(AppFont.text(12, weight: .medium))
                    Text(L.text("workout_hold_steady")).font(AppFont.text(10)).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            } else {
                Circle().fill(sensor.faceVisible && !paused ? AccentChoice.current.color : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(L.text(statusKey)).font(AppFont.text(12, weight: .medium))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
            .modifier(WorkoutGlass(shape: Capsule()))
            .accessibilityIdentifier("workout_status")
    }

    private var statusKey: String {
        if paused { return "paused" }
        if sensor.status == .interrupted { return "workout_interrupted" }
        if sensor.status == .requestingPermission { return "workout_connecting" }
        if !started { return sensor.canStart ? "workout_ready" : "workout_connecting" }
        if !sensor.faceVisible { return "workout_tracking" }
        if !sensor.isCalibrated { return "workout_measuring" }
        return "workout_counting"
    }

    private func readout(size: CGSize) -> some View {
        VStack(spacing: 6) {
            Text(L.text("workout_repetitions")).font(AppFont.text(11, weight: .medium))
                .tracking(2).foregroundStyle(.secondary)
            Text("\(count)")
                .font(AppFont.numeric(min(300, max(128, min(size.width * 0.68, size.height * 0.48)))))
                .lineLimit(1).minimumScaleFactor(0.25)
                .frame(maxWidth: .infinity).frame(height: max(158, min(330, size.height * 0.55)))
                .contentTransition(.identity).transaction { $0.animation = nil }
                .foregroundStyle(paused ? Color.secondary : Color.primary)
                .accessibilityLabel(L.format("rep_count", count)).accessibilityIdentifier("rep_counter")
        }
    }

    private func counterStage(size: CGSize) -> some View {
        let slotHeight = min(132, max(80, size.height * 0.24))
        return ZStack {
            readout(size: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    statusPill.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                }.frame(height: slotHeight)
                Spacer(minLength: 0)
                ScrollView(.vertical, showsIndicators: false) {
                    counterHint.padding(.horizontal, 24).padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                }.frame(height: slotHeight)
            }
        }.frame(width: size.width, height: size.height)
    }

    @ViewBuilder private var counterHint: some View {
        if started && sensor.status == .permissionDenied {
            settingsButton.frame(maxWidth: 420)
        } else if !started && sensor.status == .interrupted {
            Button(L.text("retry_camera")) { sensor.prepare(); beginWhenReady() }
                .buttonStyle(FilledButton()).frame(maxWidth: 420)
        } else if !sensor.isPhoneMoving && (paused || !sensor.faceVisible || !sensor.isCalibrated) {
            Text(L.text(paused ? "workout_paused_hint" : !sensor.faceVisible ? "workout_face_hint" : "distance_hold_upper"))
                .font(AppFont.text(14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 10) {
                    Image(systemName: "timer").foregroundStyle(.secondary)
                    Text(Self.elapsed(started ? context.date.timeIntervalSince(startDate) : 0)).font(AppFont.numeric(19))
                }.frame(maxWidth: .infinity).frame(height: 62)
                    .modifier(WorkoutGlass(shape: Capsule()))
            }.accessibilityLabel(L.text("total_time"))
            Button { togglePause() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .medium)).frame(width: 62, height: 62)
                    .modifier(WorkoutGlass(shape: Circle()))
            }.accessibilityLabel(L.text(paused ? "resume" : "pause")).accessibilityIdentifier("pause_workout")
                .disabled(!started)
            Button { finish() } label: {
                Image(systemName: "stop.fill").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(AccentChoice.current.color).frame(width: 62, height: 62)
                    .modifier(WorkoutGlass(shape: Circle()))
            }.accessibilityLabel(L.text("finish")).accessibilityIdentifier("finish_workout")
                .disabled(!started)
        }.foregroundStyle(.primary).buttonStyle(.plain)
            .frame(height: 62)
    }

    private func introduction(permission: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 12)
            WorkoutPlacementIllustration(permission: permission).frame(height: 190)
                .frame(maxWidth: .infinity).background(Color.panel, in: RoundedRectangle(cornerRadius: 32))
                .accessibilityHidden(true)
            Text(L.text(permission ? "distance_permission_title" : "workout_guide_title"))
                .font(AppFont.text(30, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(L.text(permission ? "distance_permission_body" : "workout_guide_body"))
                .font(AppFont.text(15)).foregroundStyle(.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(L.text("workout_continue")) {
                if permission {
                    permissionIntro = false
                    awaitingPermission = true
                    sensor.prepare()
                } else {
                    guideSeen = true
                    placementGuide = false
                    sensor.prepare()
                    beginWhenReady()
                }
            }.buttonStyle(FilledButton()).accessibilityIdentifier(permission ? "camera_permission_continue" : "placement_guide_continue")
        }
    }

    private var unavailableContent: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)
            Image(systemName: "face.dashed").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(L.text(sensor.status == .permissionDenied ? "distance_permission_title" : "distance_unavailable"))
                .font(AppFont.text(26, weight: .semibold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("distance_unavailable")
            Text(L.text(sensor.status == .permissionDenied ? "distance_permission_body" : "distance_unavailable_body"))
                .font(AppFont.text(15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 20)
            if sensor.status == .permissionDenied { settingsButton }
            else { Button(L.text("done")) { dismiss() }.buttonStyle(FilledButton()) }
        }
    }

    private var settingsButton: some View {
        Button(L.text("open_settings")) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }.buttonStyle(FilledButton())
    }

    private func summaryContent(_ result: WorkoutRecord) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Image(systemName: "checkmark").font(.system(size: 26, weight: .light))
                .foregroundStyle(AccentChoice.current.color).frame(width: 68, height: 68)
                .modifier(WorkoutGlass(shape: Circle()))
            Text(L.text("well_done")).font(AppFont.text(30, weight: .semibold))
            Text("\(result.repetitions)").font(AppFont.numeric(132)).lineLimit(1).minimumScaleFactor(0.3)
            Text(L.text("pushups_saved")).foregroundStyle(.secondary)
            if let error = store.storageError { StatusNote(text: error) }
            if let error = model.healthError { StatusNote(text: error) }
            Spacer(minLength: 20)
            Button(L.text("done")) { dismiss() }.buttonStyle(FilledButton()).accessibilityIdentifier("workout_done")
        }
    }

    private func prepareWorkout() {
        guard ARFaceTrackingConfiguration.isSupported else { sensor.prepare(); return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            permissionIntro = true
        } else if AVCaptureDevice.authorizationStatus(for: .video) == .authorized && !guideSeen {
            placementGuide = true
        } else {
            sensor.prepare()
        }
    }

    private func beginWhenReady() {
        guard !started, summary == nil, !permissionIntro, !placementGuide, !awaitingPermission,
              scenePhase == .active, sensor.canStart, !sensor.isPhoneMoving else { return }
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
        guard summary == nil else { return }
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

private struct WorkoutGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

private struct WorkoutPlacementIllustration: View {
    let permission: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                if permission {
                    RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.6), lineWidth: 3)
                        .frame(width: 88, height: 144)
                    Capsule().fill(Color.primary).frame(width: 28, height: 6).offset(y: -57)
                    Image(systemName: "faceid").font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(AccentChoice.current.color)
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: width * 0.15, y: height * 0.72))
                        path.addLine(to: CGPoint(x: width * 0.39, y: height * 0.4))
                        path.addLine(to: CGPoint(x: width * 0.66, y: height * 0.35))
                        path.move(to: CGPoint(x: width * 0.62, y: height * 0.38))
                        path.addLine(to: CGPoint(x: width * 0.57, y: height * 0.56))
                        path.addLine(to: CGPoint(x: width * 0.7, y: height * 0.76))
                    }.stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
                    Circle().fill(Color.primary).frame(width: 24, height: 24)
                        .position(x: width * 0.75, y: height * 0.32)
                    Capsule().fill(Color.primary).frame(width: 38, height: 6)
                        .position(x: width * 0.77, y: height * 0.79)
                    Path { path in
                        path.move(to: CGPoint(x: width * 0.74, y: height * 0.69))
                        path.addLine(to: CGPoint(x: width * 0.71, y: height * 0.5))
                        path.move(to: CGPoint(x: width * 0.8, y: height * 0.69))
                        path.addLine(to: CGPoint(x: width * 0.83, y: height * 0.5))
                    }.stroke(AccentChoice.current.color.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5]))
                }
            }
        }
    }
}
