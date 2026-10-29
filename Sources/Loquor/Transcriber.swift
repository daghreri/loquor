@preconcurrency import AVFoundation
import FluidAudio

/// Local speech recognition: NVIDIA Parakeet TDT 0.6B v2 through FluidAudio.
/// The model comes from `ModelStore` (inside the app, or downloaded once into
/// Loquor's own folder) and stays loaded.
actor Transcriber {
    enum Status: Equatable {
        case downloading(Double), loading, ready, failed(String)
    }

    /// Download progress, 0...1 (called off the main thread).
    private var onProgress: @Sendable (Double) -> Void = { _ in }

    func setProgressHandler(_ handler: @escaping @Sendable (Double) -> Void) {
        onProgress = handler
    }

    private var asr: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    /// Loads the model; safe to call more than once.
    func load() async throws {
        _ = try await manager()
    }

    func transcribe(_ audio: Recorder.Audio) async throws -> String {
        let asr = try await manager()
        let samples16k = try Self.resample(audio)
        // A fresh decoder state per dictation: each one is independent.
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples16k, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func manager() async throws -> AsrManager {
        if let asr { return asr }
        if loadTask == nil {
            let progress = onProgress
            loadTask = Task {
                ModelStore.pin()
                let models: AsrModels
                if let bundled = ModelStore.bundled {
                    models = try await AsrModels.load(from: bundled, version: .v2)
                } else {
                    ModelStore.adoptSharedCache()
                    models = try await AsrModels.downloadAndLoad(
                        to: ModelStore.downloaded, version: .v2,
                        progressHandler: { progress($0.fractionCompleted) })
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            }
        }
        do {
            let manager = try await loadTask!.value
            asr = manager
            return manager
        } catch {
            loadTask = nil  // let the next dictation try again
            throw error
        }
    }

    /// Native-rate mono samples -> 16 kHz mono, in one pass (no chunk seams).
    static func resample(_ audio: Recorder.Audio) throws -> [Float] {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count))
        else { return [] }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        return try AudioConverter().resampleBuffer(buffer)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
