import AppKit
import Carbon
import Combine
import SwiftUI
import LoquorCore

/// What the menu-bar icon shows.
enum DictationState {
    case idle, recording, processing

    var symbol: String {
        switch self {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .processing: "waveform"
        }
    }

    var label: String {
        switch self {
        case .idle: "Ready"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let permissions = Permissions()
    private let loginItem = LoginItem()
    private let keys = KeyMonitor()
    private let shortcuts = ShortcutStore()
    private let cleanup = CleanupSettings()
    private let connectivity = Connectivity()
    private let arabic = ArabicSupport()
    private let keyboard = KeyboardLayout()
    private var languageWatch: AnyCancellable?
    private let microphones = Microphones()
    private var shortcutWatch: AnyCancellable?
    private let recorder = Recorder()
    private let pill = Pill()
    private let transcriber = Transcriber()
    private var modelStatus: Transcriber.Status = .loading
    private var capTimer: Timer?
    private var pressedAt = ContinuousClock.now
    /// Bumped per dictation, so a slow earlier one (cleanup can take seconds)
    /// doesn't reset the icon and pill of a newer one when it finishes.
    private var job = 0
    /// The last typed text, for "Copy Last Dictation" if the paste didn't land.
    private var lastText: String?
    /// Audio that couldn't be transcribed, for "Retry Last Dictation".
    private var failedAudio: Recorder.Audio?
    private let log = KeyLog(name: "loquor.log")

    private let dictation = DictationSettings()
    /// Watches for silence while hands-free (a forgotten session finishes by itself).
    private var silenceTimer: Timer?
    /// Shorter than this is a slip of the finger, not speech.
    private static let minSeconds = 0.3

    var state: DictationState = .idle {
        didSet { updateIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMover.offerMoveIfNeeded() { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // First run, or a permission went missing: show Settings so it can be granted.
        permissions.refresh()
        // `open -a Loquor --args --settings` opens Settings straight away (handy when developing).
        // After an update macOS wants the Keychain approved again: ask here, not mid-dictation.
        let keyNeedsApproval = cleanup.enabled && permissions.keychain == .needsApproval
        if !permissions.allGranted || keyNeedsApproval || CommandLine.arguments.contains("--settings") { openSettings() }

        pill.level = { [recorder] in recorder.level }
        pill.log = { [log] line in log.write(line) }
        // Developer testing (launch with --debug): show the indicator without the keyboard,
        // e.g. over a full-screen app: post com.daghreri.loquor.debug.pill.
        if CommandLine.arguments.contains("--debug") {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.daghreri.loquor.debug.pill"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pill.show(.listening(handsFree: false))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.pill.hide() }
                }
            }
            // com.daghreri.loquor.debug.handsfree: start hands-free and leave it, to see the
            // silence stop finish it by itself.
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.daghreri.loquor.debug.handsfree"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handle(.start)
                    self?.handle(.latch)
                }
            }
            // com.daghreri.loquor.debug.record: a 4-second recording through the normal
            // pipeline (logs which microphone the engine opened).
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.daghreri.loquor.debug.record"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handle(.start)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.handle(.stop) }
                }
            }
        }
        recorder.device = { [weak self] in
            self?.microphones.refresh()
            return self?.microphones.deviceForRecording
        }
        recorder.onInputChanged = { [weak self] change in
            guard let self else { return }
            switch change {
            case .continued:
                // e.g. AirPods switching into microphone mode, or taken out mid-sentence.
                self.microphones.refresh()
                self.log.write("mic changed mid-recording, continuing on \(self.microphones.active?.name ?? "the default mic")")
            case .noMicrophone:
                self.log.write("mic changed mid-recording and no microphone is left: finishing")
                self.keys.finish()
            case .keptChanging:
                self.log.write("mic kept changing mid-recording: finishing")
                self.keys.finish()
            }
        }
        keys.onAction = { [weak self] action in self?.handle(action) }
        arabic.onLog = { [log] line in log.write(line) }
        arabic.start()
        // While listening, the indicator follows a keyboard-layout switch.
        languageWatch = keyboard.$language.sink { [weak self] _ in
            DispatchQueue.main.async { self?.showLanguage() }
        }
        shortcutWatch = shortcuts.$shortcut.sink { [weak self] shortcut in self?.keys.shortcut = shortcut }
        keys.start()
        loadModel()
    }

    private func loadModel() {
        modelStatus = .loading
        Task {
            let started = ContinuousClock.now
            await transcriber.setProgressHandler { fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.modelStatus != .ready else { return }
                    // FluidAudio reports download and then compile progress; below 1 is still fetching.
                    self.modelStatus = fraction < 1 ? .downloading(fraction) : .loading
                }
            }
            do {
                try await transcriber.load()
                modelStatus = .ready
                log.write("model ready in \(ContinuousClock.now - started) from \(ModelStore.bundled != nil ? "app bundle" : ModelStore.downloaded.path)")
            } catch {
                modelStatus = .failed(error.localizedDescription)
                log.write("model failed: \(error)")
            }
        }
    }

    /// Optional Claude cleanup. Any failure returns the raw transcript, so
    /// dictation is never lost. Only timings and reasons are logged, never text.
    private func cleanedUp(_ text: String, app: String?, language: DictationLanguage) async -> String {
        guard cleanup.active, Cleanup.shouldClean(text) else { return text }
        // Never prompt mid-dictation: if macOS would ask, type as heard and point to Settings.
        guard let key = Keychain.loadSilently() else {
            log.write("cleanup skipped: Keychain access needs approval")
            cleanup.record(.init(heard: text, typed: text, seconds: 0, note: "approve the key in Settings › General"))
            return text
        }
        guard connectivity.online else {
            log.write("cleanup skipped: offline")
            cleanup.record(.init(heard: text, typed: text, seconds: 0, note: "offline"))
            return text
        }
        pill.show(.cleaning)
        let started = ContinuousClock.now
        let model = cleanup.model
        let outcome = await Cleaner.clean(text, app: app, words: cleanup.words, model: model, key: key, language: language)
        let seconds = (ContinuousClock.now - started).seconds
        switch outcome {
        case .cleaned(let clean):
            log.write(String(format: "cleanup %@ ok in %.2fs", model, seconds))
            cleanup.record(.init(heard: text, typed: clean, seconds: seconds, note: nil))
            return clean
        case .failed(let reason):
            log.write(String(format: "cleanup %@ failed in %.2fs: %@", model, seconds, reason))
            cleanup.record(.init(heard: text, typed: text, seconds: seconds, note: reason))
            return text
        }
    }

    /// English, or Arabic when Arabic is on and an Arabic keyboard layout is active.
    private var currentLanguage: DictationLanguage {
        DictationLanguage.choose(arabicEnabled: arabic.enabled, keyboard: keyboard.language)
    }

    /// The indicator names the language only when there's a choice (Arabic on).
    private func showLanguage() {
        pill.setLanguage(arabic.enabled ? currentLanguage.label : nil)
    }

    private func handle(_ action: KeyGesture.Action) {
        switch action {
        case .start:
            pressedAt = .now
            do {
                try recorder.start()
                log.write("mic: \(microphones.active?.name ?? "none")"
                          + (microphones.chosen != nil ? " (chosen)" : microphones.chosenIsMissing ? " (chosen mic missing, system default)" : " (system default)")
                          + (recorder.deviceOpenedDirectly ? ", opened directly" : ", default route")
                          + (recorder.fellBack ? ", couldn't open it so using the default route" : ""))
                job += 1
                state = .recording
                keyboard.refresh()
                showLanguage()
                pill.show(.listening(handsFree: false))
                pill.limitSeconds = Double(dictation.maxSeconds)
                let timer = Timer(timeInterval: Double(dictation.maxSeconds), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.keys.finish() }
                }
                RunLoop.main.add(timer, forMode: .common)  // fires even while a menu is open
                capTimer = timer
            } catch {
                log.write("mic failed: \(error)")
                keys.resetGesture()
                state = .idle
                pill.flash(error.localizedDescription)
            }
        case .latch:
            pill.show(.listening(handsFree: true))  // same recording continues
            watchSilence()
        case .stop:
            capTimer?.invalidate()
            stopWatchingSilence()
            let audio = recorder.stop()
            let released = ContinuousClock.now
            guard audio.seconds >= Self.minSeconds else {
                state = .idle
                pill.hide()
                return
            }
            // The app the text goes to, for the cleanup's tone.
            let app = NSWorkspace.shared.frontmostApplication?.localizedName
            // The language is decided now, so switching layouts mid-sentence fixes a mistake.
            keyboard.refresh()
            process(audio, app: app, released: released, language: currentLanguage)
        case .cancel:
            capTimer?.invalidate()
            stopWatchingSilence()
            recorder.cancel()
            state = .idle
            pill.hide()
        case .wait:
            break
        }
    }

    /// Hands-free only: after 20 s of silence, finish and type what was said, so a
    /// forgotten session doesn't run to the limit. The indicator warns for the last 5 s.
    private func watchSilence() {
        stopWatchingSilence()
        var tracker = DictationLimits.SilenceTracker(now: Date.timeIntervalSinceReferenceDate)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let silent = tracker.update(level: self.recorder.level, now: Date.timeIntervalSinceReferenceDate)
                let left = DictationLimits.silenceSeconds - silent
                self.pill.setSilenceLeft(left <= DictationLimits.silenceWarningSeconds ? max(0, Int(left.rounded(.up))) : nil)
                if left <= 0 {
                    self.log.write("hands-free: \(Int(DictationLimits.silenceSeconds)) s of silence, finishing")
                    self.stopWatchingSilence()
                    self.keys.finish()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func stopWatchingSilence() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        pill.setSilenceLeft(nil)
    }

    /// Transcribe, optionally clean up, paste. If transcription fails the audio is
    /// kept for "Retry Last Dictation", so nothing said is lost.
    private func process(_ audio: Recorder.Audio, app: String?, released: ContinuousClock.Instant,
                         language: DictationLanguage) {
        let mine = job
        if language == .arabic && !arabic.ready {
            // Keep the audio: it can be retried once the Arabic model is ready.
            failedAudio = audio
            log.write("arabic dictation kept: model \(arabic.status)")
            pill.flash("Arabic isn't ready yet. Retry from the menu.", seconds: 4)
            state = .idle
            return
        }
        state = .processing
        if language == .arabic || modelStatus == .ready {
            pill.show(.transcribing)
        } else {
            pill.show(.message("Speech model is still loading…"))
        }
        Task {
            defer {
                if job == mine {
                    state = .idle
                    pill.hide()
                }
            }
            do {
                let text = language == .arabic
                    ? try await arabic.transcriber.transcribe(audio)
                    : try await transcriber.transcribe(audio)
                let transcribed = ContinuousClock.now
                failedAudio = nil
                if language == .english, modelStatus != .ready { modelStatus = .ready }
                guard !text.isEmpty else {
                    log.write(String(format: "audio=%.1fs empty", audio.seconds))
                    return
                }
                let typed = await cleanedUp(text, app: app, language: language)
                lastText = typed
                // Trailing space so back-to-back dictations don't run together.
                Paster.paste(typed + " ")
                log.write(String(format: "%@ audio=%.1fs words=%d", language.rawValue, audio.seconds, text.split(separator: " ").count)
                          + " release->text=\(transcribed - released) release->typed=\(ContinuousClock.now - released)")
            } catch {
                failedAudio = audio
                log.write("transcribe failed: \(error)")
                if job == mine { pill.flash("Couldn't transcribe. Retry from the menu.", seconds: 4) }
            }
        }
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: "Loquor: \(state.label)")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // Rebuilt each time it opens, so permission and login status are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        permissions.refresh()
        menu.removeAllItems()

        let status = NSMenuItem(title: "Loquor: \(statusText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let shortcut = NSMenuItem(title: "Shortcut: \(shortcuts.shortcut.displayName)", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(microphoneMenu())

        if !permissions.microphone.granted {
            menu.addItem(item("Allow Microphone…", #selector(fixMicrophone)))
        }
        if !permissions.accessibility {
            menu.addItem(item("Allow Accessibility…", #selector(fixAccessibility)))
        }
        if permissions.keychain == .needsApproval {
            menu.addItem(item("Allow Access to API Key…", #selector(fixKeychain)))
        }

        if IsSecureEventInputEnabled() {
            // Password fields and some terminals block all key monitoring while focused.
            let secure = NSMenuItem(title: "Paused: a password field has secure input on", action: nil, keyEquivalent: "")
            secure.isEnabled = false
            menu.addItem(secure)
        }

        if lastText != nil || failedAudio != nil { menu.addItem(.separator()) }
        if lastText != nil {
            menu.addItem(item("Copy Last Dictation", #selector(copyLast)))
        }
        if failedAudio != nil {
            menu.addItem(item("Retry Last Dictation", #selector(retryLast)))
        }

        if case .failed(let message) = modelStatus {
            let detail = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            menu.addItem(item("Retry Loading Model", #selector(retryModel)))
        }

        menu.addItem(.separator())
        let login = item("Start at Login", #selector(toggleLogin))
        login.state = loginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Loquor", #selector(quit)))
    }

    private var statusText: String {
        switch modelStatus {
        case .downloading(let f): "Downloading speech model… \(Int(f * 100))%"
        case .loading: "Loading speech model…"
        case .failed: "Speech model failed to load"
        case .ready: state.label
        }
    }

    /// "Microphone: AirPods Pro ›" with System Default and every input device.
    private func microphoneMenu() -> NSMenuItem {
        microphones.refresh()
        let title = "Microphone: \(microphones.active?.name ?? "None")"
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let auto = item("System Default (\(microphones.systemDefault?.name ?? "none"))", #selector(chooseMicrophone(_:)))
        auto.representedObject = nil
        auto.state = microphones.chosenUID == nil ? .on : .off
        sub.addItem(auto)
        sub.addItem(.separator())
        for device in microphones.devices {
            let entry = item(device.name, #selector(chooseMicrophone(_:)))
            entry.representedObject = device.uid
            entry.state = microphones.chosenUID == device.uid ? .on : .off
            sub.addItem(entry)
        }
        if microphones.chosenIsMissing {
            sub.addItem(.separator())
            let note = NSMenuItem(title: "Your chosen mic isn't connected; using System Default", action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
        }
        top.submenu = sub
        return top
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        microphones.chosenUID = sender.representedObject as? String
    }

    // No key equivalents: a menu-bar app never has keyboard focus, so ⌘Q / ⌘, would never fire.
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func fixMicrophone() { permissions.requestMicrophone() }
    @objc private func fixAccessibility() { permissions.requestAccessibility() }
    @objc private func fixKeychain() {
        openSettings()
        permissions.requestKeychain()
    }
    @objc private func retryModel() { loadModel() }
    @objc private func copyLast() {
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }
    @objc private func retryLast() {
        guard let audio = failedAudio else { return }
        if case .failed = modelStatus { loadModel() }
        job += 1
        keyboard.refresh()
        if currentLanguage == .arabic, case .failed = arabic.status { arabic.retry() }
        process(audio, app: NSWorkspace.shared.frontmostApplication?.localizedName, released: .now, language: currentLanguage)
    }
    @objc private func toggleLogin() { loginItem.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(permissions: permissions, loginItem: loginItem, shortcuts: shortcuts, cleanup: cleanup, connectivity: connectivity, arabic: arabic, microphones: microphones, dictation: dictation, keys: keys)
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]  // window follows each tab's height
            let window = NSWindow(contentViewController: host)
            window.title = "Loquor Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
