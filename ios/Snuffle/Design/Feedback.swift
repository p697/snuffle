import AVFoundation
import UIKit

/// Haptics and the optional ticks. Both follow the person's settings; sound also respects the silent switch.
@MainActor
final class Feedback {
    var hapticsOn = true
    var soundOn = false

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notice = UINotificationFeedbackGenerator()
    private lazy var synth = ToneSynth()

    func press() {
        guard hapticsOn else { return }
        medium.impactOccurred()
    }

    func release() {
        guard hapticsOn else { return }
        light.impactOccurred(intensity: 0.7)
    }

    /// One digit column settling.
    func tick(column: Int) {
        if hapticsOn { rigid.impactOccurred(intensity: 0.45) }
        if soundOn { synth.play(frequency: 1050 + Double(column) * 90, duration: 0.04) }
    }

    func sale() {
        if hapticsOn { notice.notificationOccurred(.success) }
        if soundOn {
            synth.play(frequency: 880, duration: 0.12)
            synth.play(frequency: 1320, duration: 0.22, delay: 0.1)
        }
    }

    func prepare() {
        medium.prepare()
        rigid.prepare()
    }
}

/// Short sine tones made on the fly, so the app ships no audio files.
@MainActor
private final class ToneSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var ready = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(frequency: Double, duration: Double, delay: Double = 0) {
        do {
            if !ready {
                try AVAudioSession.sharedInstance().setCategory(.ambient)
                try engine.start()
                player.play()
                ready = true
            }
        } catch {
            return
        }
        let silence = Int(delay * format.sampleRate)
        let frames = Int(duration * format.sampleRate) + silence
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            guard index >= silence else { samples[index] = 0; continue }
            let t = Double(index - silence) / format.sampleRate
            // Quick exponential decay, the same envelope as the prototype.
            let envelope = 0.06 * pow(0.0001 / 0.06, t / duration)
            samples[index] = Float(sin(2 * .pi * frequency * t) * envelope)
        }
        player.scheduleBuffer(buffer)
    }
}
