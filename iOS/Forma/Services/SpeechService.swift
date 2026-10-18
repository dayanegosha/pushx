import AVFAudio
import Foundation

@MainActor
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()
    private let synthesizer = AVSpeechSynthesizer()
    private var audioSessionActive = false

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(count: Int, languageCode: String) {
        guard count >= 0 else { return }
        // Keeping only the latest count prevents a voice queue from falling
        // behind a fast set of repetitions.
        synthesizer.stopSpeaking(at: .immediate)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            audioSessionActive = true
        } catch {
            // Audio setup failure never interrupts counting or changes a workout.
            return
        }
        let utterance = AVSpeechUtterance(string: String(count))
        let voiceLanguage: String
        if languageCode.hasPrefix("ru") { voiceLanguage = "ru-RU" }
        else if languageCode.hasPrefix("zh") { voiceLanguage = "zh-CN" }
        else { voiceLanguage = "en-US" }
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudio()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.deactivateAudio()
        }
    }

    private func deactivateAudio() {
        guard audioSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionActive = false
    }
}
