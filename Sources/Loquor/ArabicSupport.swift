import CoreML
import CryptoKit
import FluidAudio
import Foundation
import LoquorCore

/// Optional Arabic dictation: Cohere Transcribe (03-2026, Apache 2.0) through
/// FluidAudio. Off by default. Turning it on downloads the model once (~2.2 GB,
/// pinned to one Hugging Face commit and checked by SHA-256) into
/// ~/Library/Application Support/Loquor/Models/cohere-transcribe-03-2026.
///
/// The model runs on the CPU and Neural Engine only: with the GPU allowed, Core ML
/// unpacks the int8 encoder and memory grows by ~10 GB (FluidAudio issue #1045).
@MainActor
final class ArabicSupport: ObservableObject {
    enum Status: Equatable {
        case notDownloaded
        case downloaded            // on disk, not loaded (Arabic is off)
        case downloading(Double)   // 0...1
        case loading
        case ready
        case failed(String)
    }

    static let repo = "FluidInference/cohere-transcribe-03-2026-coreml"
    /// Commit tested with Loquor's Arabic test set (2026-10-19). Change only with a re-test.
    static let revision = "7ca8c223e84c817a7e125c567c2582559dcd8e32"
    static let folder = ModelStore.downloadRoot.appending(path: "cohere-transcribe-03-2026")
    private static let wanted = ["q8/cohere_encoder.mlmodelc/", "q8/cohere_decoder_cache_external_v2.mlmodelc/"]
    private static let marker = ".loquor-revision"

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "arabicEnabled")
            enabled ? activate() : deactivate()
        }
    }
    @Published private(set) var status: Status = .notDownloaded

    let transcriber = ArabicTranscriber()
    private var work: Task<Void, Never>?
    var onLog: (String) -> Void = { _ in }

    var isDownloaded: Bool {
        (try? String(contentsOf: Self.folder.appending(path: Self.marker), encoding: .utf8)) == Self.revision
    }
    var ready: Bool { status == .ready }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "arabicEnabled")
        status = isDownloaded ? .downloaded : .notDownloaded
    }

    /// Call at launch: loads the model if Arabic is on.
    func start() { if enabled { activate() } }

    private func activate() {
        work?.cancel()
        work = Task {
            do {
                if !isDownloaded { try await download() }
                status = .loading
                let started = ContinuousClock.now
                try await transcriber.load(from: Self.folder)
                status = .ready
                onLog("arabic model ready in \(ContinuousClock.now - started)")
            } catch is CancellationError {
            } catch {
                status = .failed(error.localizedDescription)
                onLog("arabic model failed: \(error)")
            }
        }
    }

    /// Arabic off: forget the loaded model so its memory is freed. The files stay.
    private func deactivate() {
        work?.cancel()
        work = nil
        Task { await transcriber.unload() }
        status = isDownloaded ? .downloaded : .notDownloaded
    }

    func retry() { if enabled { activate() } }

    /// Deletes the downloaded model (and turns Arabic off).
    func remove() {
        enabled = false
        try? FileManager.default.removeItem(at: Self.folder)
        status = .notDownloaded
    }

    // MARK: Download

    private struct RemoteFile: Decodable {
        let type: String
        let path: String
        let size: Int?
        let lfs: LFS?
        struct LFS: Decodable { let oid: String; let size: Int }
    }

    private func download() async throws {
        status = .downloading(0)
        let listURL = URL(string: "https://huggingface.co/api/models/\(Self.repo)/tree/\(Self.revision)?recursive=true")!
        let (data, _) = try await URLSession.shared.data(from: listURL)
        let files = try JSONDecoder().decode([RemoteFile].self, from: data).filter { f in
            f.type == "file" && (f.path == "vocab.json" || Self.wanted.contains { f.path.hasPrefix($0) })
        }
        guard files.contains(where: { $0.path.hasPrefix(Self.wanted[0]) }) else {
            throw URLError(.fileDoesNotExist)
        }
        let total = files.reduce(0) { $0 + ($1.lfs?.size ?? $1.size ?? 0) }
        var done = 0

        let fm = FileManager.default
        try? fm.removeItem(at: Self.folder)
        for file in files {
            try Task.checkCancellation()
            let target = Self.folder.appending(path: file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let remote = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/\(file.path)")!
            let base = done
            let tmp = try await Self.fetch(remote) { written in
                Task { @MainActor [weak self] in
                    self?.status = .downloading(Double(base + Int(written)) / Double(max(total, 1)))
                }
            }
            if let lfs = file.lfs {
                // Large files: check the SHA-256 Hugging Face publishes for them.
                guard try Self.sha256(of: tmp) == lfs.oid else {
                    try? fm.removeItem(at: tmp)
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            try? fm.removeItem(at: target)
            try fm.moveItem(at: tmp, to: target)
            done += file.lfs?.size ?? file.size ?? 0
        }
        try Self.revision.write(to: Self.folder.appending(path: Self.marker), atomically: true, encoding: .utf8)
    }

    /// Downloads to a temporary file, reporting bytes written. A classic download
    /// task (not the async API, which doesn't deliver progress callbacks).
    nonisolated private static func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let box = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: box, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Reports progress for one download and hands back the finished file.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var file: URL?
    var continuation: CheckedContinuation<URL, Error>?

    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns: move it somewhere of our own.
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200, (try? FileManager.default.moveItem(at: location, to: tmp)) != nil {
            lock.withLock { file = tmp }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<URL, Error> = lock.withLock {
            if let error { return .failure(error) }
            if let file { return .success(file) }
            return .failure(URLError(.badServerResponse))
        }
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

/// Runs Cohere Transcribe for Arabic dictations.
actor ArabicTranscriber {
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

    func load(from folder: URL) async throws {
        guard models == nil else { return }
        let q8 = folder.appending(path: "q8")
        models = try await CoherePipeline.loadModels(
            encoderDir: q8, decoderDir: q8, vocabDir: folder,
            computeUnits: .cpuAndNeuralEngine)  // see the note on ArabicSupport
    }

    func unload() { models = nil }

    func transcribe(_ audio: Recorder.Audio) async throws -> String {
        guard let models else { throw CocoaError(.featureUnsupported) }
        let samples = try Transcriber.resample(audio)
        // transcribeLong stitches 35-second windows, so a 60-second dictation works too.
        let result = try await pipeline.transcribeLong(audio: samples, models: models, language: .arabic)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
