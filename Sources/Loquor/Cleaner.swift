import LoquorCore
import Foundation

// Recent results show "heard → typed" in Settings; they live in memory only.

/// Sends a transcript to Claude for cleanup over plain HTTPS (there's no official
/// Swift SDK). Returns `.failed` on any problem so the raw text is typed instead.
enum Cleaner {
    /// One session for the app's lifetime (a session per request is never freed).
    /// Per-request deadlines come from `withDeadline`.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral  // no cookies, no cache on disk
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private static func request(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Cleanup.apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    private struct DeadlinePassed: Error {}

    /// Runs `operation`, or gives up after `seconds` (the request is cancelled).
    private static func withDeadline<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw DeadlinePassed()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Past the model's timeout the raw transcript is typed: dictation is never held up for long.
    static func clean(_ transcript: String, app: String?, words: [String], model: String, key: String) async -> Cleanup.Outcome {
        let timeout = Cleanup.ModelProfile.of(model).timeout
        var request = request(Cleanup.endpoint, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta = Cleanup.betaHeader(model: model) { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: Cleanup.requestBody(transcript: transcript, app: app, words: words, model: model))
            let sending = request
            let (data, response) = try await withDeadline(timeout) { try await session.data(for: sending) }
            return Cleanup.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch is DeadlinePassed {
            return .failed("timed out after \(Int(timeout)) s")
        } catch {
            return .failed("network: \((error as? URLError)?.code.rawValue ?? -1)")
        }
    }

    enum KeyCheck {
        case works([(id: String, name: String)])
        case rejected(Int)   // HTTP status, e.g. 401
        case unreachable
    }

    /// Checks a key with GET /v1/models and returns the Claude models it can use.
    static func check(key: String) async -> KeyCheck {
        let url = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
        let sending = request(url, key: key)
        guard let (data, response) = try? await withDeadline(10, { try await session.data(for: sending) }) else {
            return .unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return .rejected(status) }
        return .works(Cleanup.usableModels(fromModelsResponse: data))
    }
}

/// Cleanup settings (in the app's preferences; the key is in the Keychain) and
/// the last few results, kept in memory only so Settings can show them.
@MainActor
final class CleanupSettings: ObservableObject {
    struct Recent: Identifiable {
        let id = UUID()
        let heard: String
        let typed: String
        let seconds: Double
        let note: String?   // why the raw text was typed, if it was
    }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "cleanupEnabled") }
    }
    @Published var words: [String] {
        didSet { UserDefaults.standard.set(words, forKey: "cleanupWords") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "cleanupModel") }
    }
    /// What the key can use, from the Models API; empty until fetched.
    @Published private(set) var models: [Model] = []
    @Published private(set) var hasKey = Keychain.hasKey

    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
    }
    @Published private(set) var recent: [Recent] = []

    /// Off by default; on only when the user turns it on and a key is saved.
    var active: Bool { enabled && hasKey }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "cleanupEnabled")
        words = UserDefaults.standard.stringArray(forKey: "cleanupWords") ?? []
        model = UserDefaults.standard.string(forKey: "cleanupModel") ?? Cleanup.defaultModel
    }

    /// Asks Anthropic which models the saved key can use.
    func refreshModels() {
        guard let key = Keychain.loadSilently() else { models = []; return }
        Task {
            if case .works(let list) = await Cleaner.check(key: key) {
                models = list.map { Model(id: $0.id, name: $0.name) }
            }
        }
    }

    /// Checks the key on the clipboard with Anthropic, then saves it to the Keychain
    /// and clears the clipboard. A key Anthropic rejects isn't saved. Returns a
    /// message for the user.
    func saveKeyFromClipboard(_ clipboard: String?) async -> String {
        let key = (clipboard ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Anthropic keys start with "sk-ant-"; the part after it varies by key type,
        // so let Anthropic decide whether this one works.
        guard key.hasPrefix("sk-ant-"), key.count > 20, !key.contains(where: \.isWhitespace) else {
            return "The clipboard doesn't hold an Anthropic API key (it starts with sk-ant-). Copy it first, then try again."
        }
        // The kind of key, for messages: "sk-ant-api03", "sk-ant-admin01"… (not the secret part).
        let kind = key.split(separator: "-").prefix(3).joined(separator: "-")
        let check = await Cleaner.check(key: key)
        if case .rejected(let status) = check {
            let hint = kind.hasPrefix("sk-ant-api") ? "" : " This looks like a \(kind) key; Loquor needs an API key from console.anthropic.com › API keys."
            return status == 401 ? "Anthropic rejected this key (401). Nothing was saved.\(hint)"
                                 : "Anthropic didn't accept this key (HTTP \(status)). Nothing was saved.\(hint)"
        }
        guard Keychain.save(key) else { return "Couldn't save the key to the Keychain." }
        hasKey = true
        if !enabled { enabled = true }
        if case .works(let list) = check {
            models = list.map { Model(id: $0.id, name: $0.name) }
            return "Key works and is saved in the Keychain; clipboard cleared."
        }
        return "Key saved in the Keychain; clipboard cleared. Couldn't reach Anthropic to check it (offline?)."
    }

    func removeKey() {
        Keychain.delete()
        hasKey = false
        models = []
    }

    func record(_ item: Recent) {
        recent.insert(item, at: 0)
        if recent.count > 5 { recent.removeLast() }
    }
}
