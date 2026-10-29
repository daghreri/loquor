import AppKit
import LoquorCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var permissions: Permissions
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var shortcuts: ShortcutStore
    @ObservedObject var cleanup: CleanupSettings
    @ObservedObject var connectivity: Connectivity
    @ObservedObject var arabic: ArabicSupport
    let keys: KeyMonitor

    // macOS doesn't announce permission changes, so poll while the window is open.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            Form {
                ShortcutSection(store: shortcuts, keys: keys)
                LanguagesSection(arabic: arabic)
                PermissionsSection(permissions: permissions)
                Section {
                    Toggle("Start at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                    if let error = loginItem.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                CleanupSection(settings: cleanup, online: connectivity.online)
            }
            .formStyle(.grouped)
            .tabItem { Label("Cleanup", systemImage: "sparkles") }

            Form {
                AboutSection(arabicDownloaded: arabic.isDownloaded)
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500)
        .fixedSize()
        .onAppear(perform: permissions.refresh)
        .onReceive(timer) { _ in permissions.refresh() }
    }
}

/// One line once everything is allowed; the full rows only when something's missing.
private struct PermissionsSection: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        Section("Permissions") {
            if permissions.allGranted && permissions.keychain != .needsApproval {
                Label(permissions.keychain == .allowed ? "Microphone, Accessibility and your API key are allowed."
                                                       : "Microphone and Accessibility are allowed.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                PermissionRow(
                    title: "Microphone",
                    detail: "To hear you while you dictate. Audio never leaves this Mac.",
                    granted: permissions.microphone.granted,
                    action: permissions.requestMicrophone)
                PermissionRow(
                    title: "Accessibility",
                    detail: "To notice the shortcut and paste text into the app you're using.",
                    granted: permissions.accessibility,
                    action: permissions.requestAccessibility)
                if permissions.keychain != .noKey {
                    PermissionRow(
                        title: "API key in Keychain",
                        detail: permissions.keychain == .allowed
                            ? "Loquor can use your key for cleanup."
                            : "macOS asks once after each update. Click Allow…, enter your Mac password, then choose “Always Allow”. Until then, text is typed as heard.",
                        granted: permissions.keychain == .allowed,
                        action: permissions.requestKeychain)
                }
            }
        }
    }
}

// MARK: - Shortcut

private struct ShortcutSection: View {
    @ObservedObject var store: ShortcutStore
    let keys: KeyMonitor

    @State private var capturing = false
    @State private var candidate: Shortcut?
    @State private var refresh = 0  // re-read macOS settings when the window comes back

    var body: some View {
        Section {
            if capturing {
                HStack {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    Text("Press the keys you want, then let go…")
                    Spacer()
                    Button("Cancel") {
                        keys.cancelCapture()
                        capturing = false
                    }
                }
                Text("Modifiers on their own (like fn + Left Shift or Right Option) or modifiers with a key (like Control + Option + D). Press Esc alone to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let candidate {
                let issues = SystemShortcuts.issues(for: candidate)
                LabeledContent("New shortcut") { KeysLabel(shortcut: candidate) }
                IssueList(issues: issues, clean: "Free: nothing on this Mac uses it.")
                HStack {
                    Button("Try Another…", action: startCapture)
                    Spacer()
                    Button("Cancel") { self.candidate = nil }
                    Button("Use This Shortcut") {
                        store.shortcut = candidate
                        self.candidate = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(issues.first?.severity == .blocked)
                }
            } else {
                LabeledContent("Shortcut") {
                    HStack {
                        KeysLabel(shortcut: store.shortcut)
                        Button("Change…", action: startCapture)
                    }
                }
                IssueList(issues: SystemShortcuts.issues(for: store.shortcut), clean: nil)
                    .id(refresh)
                if store.shortcut != .default {
                    Button("Reset to fn + Left Shift") { store.shortcut = .default }
                        .buttonStyle(.link)
                }
            }
        } header: {
            Text("Dictation shortcut")
        } footer: {
            Text("Hold to talk. Double-tap for hands-free; press again or Esc to finish.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh += 1
        }
    }

    private func startCapture() {
        candidate = nil
        capturing = true
        keys.capture { shortcut in
            capturing = false
            candidate = shortcut
        }
    }
}

private struct KeysLabel: View {
    let shortcut: Shortcut

    var body: some View {
        Text(shortcut.displayName)
            .font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }
}

private struct IssueList: View {
    let issues: [ShortcutIssue]
    let clean: String?

    var body: some View {
        if issues.isEmpty {
            if let clean {
                Label(clean, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        } else {
            ForEach(issues.indices, id: \.self) { i in
                let issue = issues[i]
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: icon(issue.severity)).foregroundStyle(color(issue.severity))
                    Text(issue.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let fix = issue.fix {
                        Button("Open Keyboard Settings…") { SystemShortcuts.open(fix) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func icon(_ s: ShortcutIssue.Severity) -> String {
        switch s {
        case .blocked: "xmark.octagon.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .note: "info.circle"
        }
    }

    private func color(_ s: ShortcutIssue.Severity) -> Color {
        switch s {
        case .blocked: .red
        case .conflict: .orange
        case .warning: .yellow
        case .note: .secondary
        }
    }
}

// MARK: - Languages

/// English is always on. Arabic is opt-in: when off, Loquor ignores the keyboard
/// layout entirely; when on, an Arabic layout means an Arabic dictation.
private struct LanguagesSection: View {
    @ObservedObject var arabic: ArabicSupport

    var body: some View {
        Section {
            LabeledContent("English") {
                Text("Always on").foregroundStyle(.secondary)
            }
            Toggle(isOn: $arabic.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arabic · عربي")
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .downloading(let fraction) = arabic.status {
                ProgressView(value: fraction) {
                    Text("Downloading the Arabic model… \(Int(fraction * 100))%").font(.caption)
                }
            }
            if case .failed(let message) = arabic.status {
                HStack(alignment: .firstTextBaseline) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Retry", action: arabic.retry).controlSize(.small)
                }
            }
            if !arabic.enabled && arabic.isDownloaded {
                HStack {
                    Text("The Arabic model is downloaded (about 2.2 GB).").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", action: arabic.remove).controlSize(.small)
                }
            }
        } header: {
            Text("Languages")
        } footer: {
            Text("With Arabic on, the keyboard layout picks the language: switch layouts (⌃Space or 🌐) to change it, even mid-sentence.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        switch arabic.status {
        case .notDownloaded: "Off. Turning it on downloads the Arabic model (about 2.2 GB) once."
        case .downloaded: "Off: Loquor ignores the keyboard layout and dictates in English."
        case .downloading: "Downloading…"
        case .loading: "Loading the Arabic model…"
        case .ready: "On: an Arabic keyboard layout means Arabic; any other layout means English."
        case .failed: "The Arabic model couldn't be loaded."
        }
    }
}

// MARK: - Cleanup

private struct CleanupSection: View {
    @ObservedObject var settings: CleanupSettings
    let online: Bool
    @State private var notice: String?
    @State private var wordsText = ""

    var body: some View {
        Section {
            Toggle(isOn: $settings.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up with Claude")
                    Text(!settings.active ? "Off: text is typed exactly as heard."
                         : !online ? "Offline: typing as heard until you're back online."
                         : "Fixes grammar, punctuation and misheard words; removes “um” and false starts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.hasKey)

            LabeledContent("Anthropic API key") {
                HStack {
                    Text(settings.hasKey ? "Saved in the Keychain" : "Not set")
                        .foregroundStyle(settings.hasKey ? Color.secondary : Color.orange)
                    Button(settings.hasKey ? "Replace from Clipboard" : "Paste from Clipboard") {
                        let board = NSPasteboard.general
                        let pasted = board.string(forType: .string)
                        notice = "Checking the key with Anthropic…"
                        Task {
                            let before = Keychain.loadSilently()
                            notice = await settings.saveKeyFromClipboard(pasted)
                            // Clear the clipboard only once this key is safely saved,
                            // so a rejected key can be fixed and pasted again.
                            let saved = pasted.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            if let saved, saved != before, Keychain.loadSilently() == saved,
                               board.string(forType: .string) == pasted {
                                board.clearContents()
                            }
                        }
                    }
                    if settings.hasKey {
                        Button("Remove") {
                            settings.removeKey()
                            notice = "Key removed."
                        }
                    }
                }
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            if settings.hasKey {
                Picker("Model", selection: $settings.model) {
                    ForEach(choices) { m in
                        Text(m.id == Cleanup.defaultModel ? "\(m.name) (fastest, default)" : m.name).tag(m.id)
                    }
                }
                Text(modelHint).font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Your words", text: $wordsText, prompt: Text("Names and terms it mishears, comma-separated"))
                    .onSubmit(saveWords)
                Text("Spelled this way when you say something close. Return to save.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !settings.recent.isEmpty {
                DisclosureGroup("Recent (\(settings.recent.count))") {
                    ForEach(settings.recent) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.1f s", r.seconds) + (r.note.map { " · typed as heard: \($0)" } ?? ""))
                                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            Text("Heard: \(r.heard)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("Typed: \(r.typed)").font(.caption).lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: {
            Text("Text cleanup")
        } footer: {
            Text("Sends the transcript, the app's name and your words (never audio) to Anthropic with your key. Slow, failed or offline: typed as heard.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            wordsText = settings.words.joined(separator: ", ")
            settings.refreshModels()
        }
    }

    /// The key's models, always including the current choice and the default.
    private var choices: [CleanupSettings.Model] {
        var list = settings.models
        for id in [settings.model, Cleanup.defaultModel] where !list.contains(where: { $0.id == id }) {
            list.insert(.init(id: id, name: id), at: 0)
        }
        return list
    }

    private var modelHint: String {
        let p = Cleanup.ModelProfile.of(settings.model)
        if settings.model == Cleanup.defaultModel { return "Haiku 5.5 is the fastest and cheapest; usually about a second." }
        return "Bigger models can be slower; after \(Int(p.timeout)) s your words are typed as heard."
    }

    private func saveWords() {
        settings.words = wordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        wordsText = settings.words.joined(separator: ", ")
    }
}

// MARK: - Permissions

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Allow…", action: action)
            }
        }
    }
}

// MARK: - About

/// What Loquor is built from, so people know what runs on their Mac and what doesn't.
private struct AboutSection: View {
    var arabicDownloaded = false

    private static var modelFolder: URL { ModelStore.location }

    var body: some View {
        Section("About") {
            LabeledContent("Speech model") {
                AboutValue("NVIDIA Parakeet TDT 0.6B v2", "English · runs on this Mac · CC BY 4.0, by NVIDIA")
            }
            if arabicDownloaded {
                LabeledContent("Arabic model") {
                    AboutValue("Cohere Transcribe 03-2026", "Runs on this Mac (Neural Engine) · Apache 2.0, by Cohere")
                }
            }
            LabeledContent("Engine") {
                AboutValue("FluidAudio 0.17.7", "Core ML on the Apple Neural Engine · Apache 2.0")
            }
            LabeledContent("Audio") {
                AboutValue("Microphone via AVAudioEngine", "16 kHz mono · only while dictating · never saved or sent")
            }
            LabeledContent("Text cleanup") {
                AboutValue("Claude, your choice of model", "Off unless you add a key · sends the transcript, app name and your words")
            }
            LabeledContent("Typing") {
                AboutValue("Paste with ⌘V", "Your clipboard is put back afterwards · never presses Return")
            }
            LabeledContent("Model files") {
                HStack {
                    Text((ModelStore.bundled != nil ? "Inside the app · " : "Downloaded · ") + Self.folderSize())
                        .foregroundStyle(.secondary)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Self.modelFolder])
                    }
                    .controlSize(.small)
                }
            }
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            LabeledContent("License") {
                HStack {
                    Text("MIT").foregroundStyle(.secondary)
                    Button("Acknowledgements") {
                        if let notice = Bundle.main.url(forResource: "NOTICE", withExtension: nil) {
                            NSWorkspace.shared.open(notice)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private static func folderSize() -> String {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: modelFolder, includingPropertiesForKeys: keys) else {
            return "Not downloaded"
        }
        var bytes = 0
        for case let url as URL in files {
            bytes += (try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0
        }
        return bytes == 0 ? "Not downloaded" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct AboutValue: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
