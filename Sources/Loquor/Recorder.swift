@preconcurrency import AVFoundation
import CoreAudio

/// Records the microphone while dictating. Samples are kept at the input's native
/// rate (mono, first channel) and resampled once at the end. The engine runs only
/// while recording, so the mic indicator is off otherwise.
///
/// If the input changes mid-recording (AirPods switching into microphone mode about
/// a second in, AirPods taken out, another default chosen), the engine stops; the
/// recorder restarts it on the right microphone and keeps going in a new segment,
/// since the sample rate can differ (AirPods' microphone mode is 16–24 kHz).
final class Recorder: @unchecked Sendable {
    struct Segment {
        let samples: [Float]
        let sampleRate: Double
    }

    struct Audio {
        let segments: [Segment]
        var seconds: Double { segments.reduce(0) { $0 + Double($1.samples.count) / $1.sampleRate } }
    }

    enum RecorderError: LocalizedError {
        case noInput

        var errorDescription: String? { "No microphone is available." }
    }

    /// Asked for the microphone to (re)start on: a device to open directly, or nil to
    /// record through macOS's default input route.
    var device: @MainActor () -> AudioDeviceID? = { nil }
    /// The last start couldn't open the requested device and used the default route.
    private(set) var fellBack = false
    enum Change {
        case continued(AudioDeviceID)
        case noMicrophone
        case keptChanging
    }

    /// Called on the main queue after an input change. Anything but `.continued`
    /// means the recording should be finished with what was captured.
    var onInputChanged: @MainActor (Change) -> Void = { _ in }

    /// A mic change arrives as a burst of notifications (AirPods switching into
    /// microphone mode send several): wait this long after the last one, then restart.
    private static let settle: Double = 0.5
    private static let maxRestarts = 5
    private var restartToken = 0
    private var recording = false

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var finished: [Segment] = []
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var lastLevel: Float = 0
    private var restarts = 0
    /// Frames received so far, to tell a harmless change (audio still arriving) from
    /// a real stop (silence).
    private var totalFrames = 0

    /// Loudness of the latest buffer, 0...1, for the on-screen waveform.
    var level: Float { lock.withLock { lastLevel } }

    /// The device the engine actually opened (0 if unknown).
    private(set) var openedDevice: AudioDeviceID = 0
    /// Whether the last open pinned a device rather than using the default route.
    private(set) var deviceOpenedDirectly = false

    /// Starts a new recording.
    @MainActor
    func start() throws {
        halt()
        lock.withLock {
            finished = []
            samples = []
            totalFrames = 0
        }
        restarts = 0
        recording = true
        try openOrFallBack(device())
    }

    /// Opens `device`; if a directly opened device fails (e.g. a Bluetooth headset
    /// mid-switch), records through the default route instead of failing.
    @MainActor
    private func openOrFallBack(_ device: AudioDeviceID?) throws {
        fellBack = false
        do {
            try open(device)
        } catch where device != nil {
            fellBack = true
            try open(nil)
        }
    }

    /// Stops and returns what was recorded.
    func stop() -> Audio {
        recording = false
        restartToken += 1
        halt()
        return lock.withLock {
            Audio(segments: finished + (samples.isEmpty ? [] : [Segment(samples: samples, sampleRate: sampleRate)]))
        }
    }

    /// Stops and throws the recording away.
    func cancel() {
        recording = false
        restartToken += 1
        halt()
        lock.withLock {
            finished = []
            samples = []
        }
    }

    // MARK: Engine

    @MainActor
    private func open(_ device: AudioDeviceID?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        deviceOpenedDirectly = device != nil
        if var id = device, let unit = input.audioUnit {
            // Pin the microphone; must happen before reading the input format.
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if let unit = input.audioUnit {
            var opened = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &opened, &size)
            openedDevice = opened
        }
        // Without any input device the format is 0 Hz / 0 channels, and installTap
        // would raise an Objective-C exception that Swift can't catch.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw RecorderError.noInput }
        // Tap with the format the device actually delivers (nil), not one read up front:
        // after pinning a device the cached format can still be the previous device's,
        // and asking for it fails with -10868 (format not supported). The sample rate
        // is taken from the buffers themselves.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tapBlock())
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged() }
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

    /// The tap callback. Built outside the main-actor `open()`: a closure created there
    /// is main-actor isolated, and Swift 6 traps when Core Audio calls it on its own
    /// realtime thread (crash seen 2026-11-02). It only touches lock-protected state.
    private nonisolated func tapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            let level = Self.level(chunk)
            let rate = buffer.format.sampleRate
            self.lock.withLock {
                if rate != self.sampleRate {
                    if !self.samples.isEmpty {
                        self.finished.append(Segment(samples: self.samples, sampleRate: self.sampleRate))
                        self.samples = []
                    }
                    self.sampleRate = rate
                }
                self.samples.append(contentsOf: chunk)
                self.totalFrames += chunk.count
                self.lastLevel = level
            }
        }
    }

    /// The input changed: keep what was captured as a segment, wait for the mic to
    /// settle, then carry on with the right microphone (or report why not).
    @MainActor
    private func inputChanged() {
        guard recording else { return }
        // Opening a device sends a change notification right after start, usually while
        // audio keeps arriving (measured). So wait for the burst to settle, then look:
        // audio still arriving means nothing to do; silence or a stopped engine means
        // restart on the right mic in a new segment.
        let framesBefore = lock.withLock { totalFrames }
        restartToken += 1
        let token = restartToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.recording, self.restartToken == token else { return }
                let flowing = self.lock.withLock { self.totalFrames } > framesBefore
                if let engine = self.engine, engine.isRunning, flowing { return }
                self.halt()
                self.lock.withLock {
                    if !self.samples.isEmpty {
                        self.finished.append(Segment(samples: self.samples, sampleRate: self.sampleRate))
                    }
                    self.samples = []
                }
                self.restarts += 1
                guard self.restarts <= Self.maxRestarts else {
                    self.onInputChanged(.keptChanging)
                    return
                }
                do {
                    try self.openOrFallBack(self.device())
                    self.onInputChanged(.continued(self.openedDevice))
                } catch {
                    self.onInputChanged(.noMicrophone)
                }
            }
        }
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
