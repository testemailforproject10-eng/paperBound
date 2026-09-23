//
//  SpeechController.swift
//  Paperbound
//
//  Reads the current page aloud with AVSpeechSynthesizer. Text comes from the
//  engine's extracted text layer, which is exactly why the composited physical
//  page never replaces that layer — a rasterized page has nothing to speak.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class SpeechController: NSObject {

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    private(set) var spokenRange: Range<Int>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, rate: Double) {
        stop()
        let cleaned = text
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        configureAudioSession()

        let utterance = AVSpeechUtterance(string: cleaned)
        // AVSpeechUtterance's usable band is narrow; map 0…1 onto it rather than
        // handing the raw slider value straight through.
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate
            + Float(rate.clamped(to: 0...1)) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * 0.62
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.2
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        spokenRange = nil
        deactivateAudioSession()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Speech still works without an explicit session on most routes;
            // failing here should not prevent reading.
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.spokenRange = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.spokenRange = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let range = characterRange.location..<(characterRange.location + characterRange.length)
        Task { @MainActor [weak self] in
            self?.spokenRange = range
        }
    }
}
