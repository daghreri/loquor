@preconcurrency import AVFoundation

/// Records the default microphone while dictating. Samples are kept at the
/// input's native rate (mono, first channel) and resampled once at the end.
/// The engine runs only while recording, so the mic indicator is off otherwise.
final class Recorder: @unchecked Sendable {
    struct Audio {
        let samples: [Float]
        let sampleRate: Double
        var seconds: Double { Double(samples.count) / sampleRate }
    }

    enum RecorderError: LocalizedError {
        case noInput

        var errorDescription: String? { "No microphone is available." }
    }

    /// Called on the main queue when the input device changes mid-recording
    /// (AirPods connect, default input switched): the engine has stopped, so
    /// the recording should be finished with what was captured.
    var onInputChanged: @MainActor () -> Void = {}

    /// A fresh engine per recording, so it always uses the current default input.
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var lastLevel: Float = 0

    /// Loudness of the latest buffer, 0...1, for the on-screen waveform.
    var level: Float { lock.withLock { lastLevel } }

    func start() throws {
        halt()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Without any input device the format is 0 Hz / 0 channels, and installTap
        // would raise an Objective-C exception that Swift can't catch.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            sampleRate = format.sampleRate
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            let level = Self.level(chunk)
            self.lock.withLock {
                self.samples.append(contentsOf: chunk)
                self.lastLevel = level
            }
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInputChanged() }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            throw error
        }
        self.engine = engine
    }

    /// Stops and returns what was recorded.
    func stop() -> Audio {
        halt()
        return lock.withLock { Audio(samples: samples, sampleRate: sampleRate) }
    }

    /// Stops and throws the recording away.
    func cancel() {
        halt()
        lock.withLock { samples.removeAll() }
    }

    private func halt() {
        removeObserver()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        lock.withLock { lastLevel = 0 }
    }

    private func removeObserver() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }

    /// RMS mapped from about -50...-10 dBFS to 0...1, so normal speech fills the range.
    private static func level(_ chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for x in chunk { sum += x * x }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 40, 0), 1)
    }
}
