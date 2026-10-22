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
    @State private var displayedNotice: WorkoutNotice?

    private var count: Int { sensor.count }
    private var unavailable: Bool { !started && (sensor.status == .unavailable || sensor.status == .permissionDenied) }

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                GeometryReader { geometry in
                    if permissionIntro || placementGuide {
                        introduction(permission: permissionIntro)
                    } else if summary != nil || unavailable {
                        ScrollView {
                            VStack(spacing: 24) {
                                if let result = summary {
                                    summaryContent(result)
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
        .task(id: noticeCandidate) {
            await updateNotice(to: noticeCandidate)
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

    private var noticeCandidate: WorkoutNotice? {
        guard summary == nil, !permissionIntro, !placementGuide, !unavailable else { return nil }
        if sensor.status == .permissionDenied { return .permission }
        if sensor.status == .interrupted { return .interrupted }
        if paused { return .paused }
        if sensor.isPhoneMoving { return .moving }
        if !started { return .connecting }
        if !sensor.faceVisible { return .tracking }
        if sensor.status == .measuring || !sensor.isCalibrated { return .measuring }
        return nil
    }

    private func updateNotice(to candidate: WorkoutNotice?) async {
        guard candidate != displayedNotice else { return }
        let delay = candidate?.presentationDelay ?? 600_000_000
        if delay > 0 {
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
        }
        guard !Task.isCancelled, noticeCandidate == candidate else { return }
        withAnimation(.easeInOut(duration: 0.16)) { displayedNotice = candidate }
    }

    private func noticeBanner(_ notice: WorkoutNotice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: notice.symbol).font(.system(size: 17, weight: .regular))
                    .foregroundStyle(AccentChoice.current.color).frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.text(notice.titleKey)).font(AppFont.text(12, weight: .medium))
                    Text(L.text(notice.detailKey)).font(AppFont.text(11)).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            if notice == .permission {
                Button(L.text("open_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(.bordered).controlSize(.small)
            } else if notice == .interrupted {
                Button(L.text("retry_camera")) { retryTracking() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .modifier(WorkoutGlass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .accessibilityElement(children: notice == .permission || notice == .interrupted ? .contain : .combine)
        .accessibilityIdentifier("workout_status")
    }

    private func readout(size: CGSize) -> some View {
        let fontSize = min(240, max(128, min(size.width * 0.56, size.height * 0.43)))
        return Text("\(count)")
                .font(AppFont.counter(fontSize)).tracking(-fontSize * 0.035)
                .lineLimit(1).minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity).frame(height: max(158, min(330, size.height * 0.55)))
                .contentTransition(.identity).transaction { $0.animation = nil }
                .foregroundStyle(paused ? Color.secondary : Color.primary)
                .accessibilityLabel(L.format("rep_count", count)).accessibilityIdentifier("rep_counter")
    }

    private func counterStage(size: CGSize) -> some View {
        let noticeHeight = min(148, max(104, size.height * 0.25))
        return ZStack(alignment: .top) {
            readout(size: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .top) {
                    if let notice = displayedNotice {
                        noticeBanner(notice).id(notice).transition(.opacity)
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }.frame(height: noticeHeight)
        }.frame(width: size.width, height: size.height)
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
        VStack(alignment: .leading, spacing: 0) {
            PushMark().stroke(Color.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: 64, height: 64).padding(.bottom, 32)
                .accessibilityElement(children: .ignore).accessibilityLabel("pushx")
                .accessibilityIdentifier("workout_intro_mark")
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text(L.text(permission ? "distance_permission_title" : "workout_guide_title"))
                        .font(AppFont.text(28, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    if permission {
                        Text(L.text("distance_permission_body"))
                            .font(AppFont.text(15)).foregroundStyle(.secondary).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            placementStep(1, key: "workout_placement_one")
                            placementStep(2, key: "workout_placement_two")
                            placementStep(3, key: "workout_placement_three")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
            }
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
            }.buttonStyle(FilledButton())
                .accessibilityIdentifier(permission ? "camera_permission_continue" : "placement_guide_continue")
                .padding(.top, 24).padding(.bottom, 20)
        }.padding(.horizontal, 24).padding(.top, 28)
            .frame(maxWidth: 620).frame(maxWidth: .infinity, alignment: .top)
    }

    private func placementStep(_ number: Int, key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(String(format: "%02d", number)).font(AppFont.text(12, weight: .medium))
                .foregroundStyle(AccentChoice.current.color).fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 24, alignment: .leading)
            Text(L.text(key)).font(AppFont.text(15)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("\(result.repetitions)").font(AppFont.counter(132)).tracking(-4).lineLimit(1).minimumScaleFactor(0.55)
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

    private func retryTracking() {
        if started {
            guard sensor.resume() else { return }
            paused = false
        } else {
            sensor.prepare()
            beginWhenReady()
        }
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

enum WorkoutNotice: Hashable {
    case connecting, measuring, tracking, moving, paused, interrupted, permission

    var presentationDelay: UInt64 {
        switch self {
        case .paused, .interrupted, .permission: return 0
        case .moving, .connecting: return 350_000_000
        case .tracking, .measuring: return 800_000_000
        }
    }

    var symbol: String {
        switch self {
        case .connecting: return "circle.dotted"
        case .measuring: return "ruler"
        case .tracking: return "eye"
        case .moving: return "waveform.path"
        case .paused: return "pause"
        case .interrupted: return "arrow.clockwise"
        case .permission: return "lock"
        }
    }

    var titleKey: String {
        switch self {
        case .connecting: return "workout_connecting"
        case .measuring: return "workout_measuring"
        case .tracking: return "workout_tracking"
        case .moving: return "workout_phone_moving"
        case .paused: return "paused"
        case .interrupted: return "workout_interrupted"
        case .permission: return "distance_permission_title"
        }
    }

    var detailKey: String {
        switch self {
        case .connecting: return "workout_notice_connecting"
        case .measuring: return "distance_hold_upper"
        case .tracking: return "workout_notice_face"
        case .moving: return "workout_hold_steady"
        case .paused: return "workout_notice_paused"
        case .interrupted: return "workout_notice_interrupted"
        case .permission: return "workout_notice_permission"
        }
    }
}
