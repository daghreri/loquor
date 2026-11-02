import Foundation

/// How long a dictation may run, and when hands-free stops on its own.
public enum DictationLimits {
    /// Choices for the longest dictation, in seconds. One minute by default; up to
    /// three, a safe range for memory, transcription time and cleanup.
    public static let choices = [60, 120, 180]
    public static let defaultSeconds = 60

    /// A saved value, kept to one of the choices.
    public static func clamp(_ seconds: Int) -> Int {
        choices.contains(seconds) ? seconds : defaultSeconds
    }

    /// Hands-free finishes by itself after this much silence (a forgotten session).
    public static let silenceSeconds = 20.0
    /// The indicator warns in the last few seconds of silence.
    public static let silenceWarningSeconds = 5.0
    /// Waveform level (0...1, about -50...-10 dBFS) at or below which a moment counts
    /// as silence. Speech is well above it; a quiet room sits below.
    public static let silenceLevel: Float = 0.2

    /// Tracks silence while hands-free: feed it the level a few times a second.
    public struct SilenceTracker: Sendable {
        private var lastVoice: Double

        public init(now: Double) { lastVoice = now }

        /// Seconds of silence so far after this reading.
        public mutating func update(level: Float, now: Double) -> Double {
            if level > DictationLimits.silenceLevel { lastVoice = now }
            return now - lastVoice
        }
    }
}
