import AppKit
@preconcurrency import CoreGraphics
import LoquorCore

/// Watches the dictation shortcut and Esc through a CGEventTap (needs
/// Accessibility) and feeds presses and releases to `KeyGesture`.
///
/// The shortcut is "pressed" when exactly its modifiers (and its key, if it has
/// one) are down, and "released" when any of them comes up. Another key pressed
/// while it's held means it was part of some other shortcut, so the recording
/// is thrown away. While the shortcut is in use, its timings are logged to
/// ~/Library/Logs/Loquor/keys.log (never other typing, never key codes).
///
/// The same tap records a new shortcut for Settings (`capture`).
@MainActor
final class KeyMonitor {
    var onAction: (KeyGesture.Action) -> Void = { _ in }
    var shortcut: Shortcut = .default {
        didSet { resetChord() }
    }

    private var gesture = KeyGesture()
    private var tap: CFMachPort?
    private var retryTimer: Timer?
    private var held: Modifiers = []
    private var chordDown = false
    /// fn was part of a shortcut press: its own action (emoji picker / macOS
    /// dictation) must not fire when it comes up.
    private var swallowFnRelease = false
    private let log = KeyLog()

    private var capture: Capture?

    private static let fnKeyCode: Int64 = 63      // kVK_Function
    private static let escKeyCode: UInt16 = 53    // kVK_Escape

    // MARK: Starting

    /// Starts the tap now or as soon as Accessibility is granted, and keeps it
    /// healthy: if Accessibility is revoked and granted again, or macOS turns the
    /// tap off, it's reinstalled without a relaunch.
    func start() {
        _ = installTap()
        let watchdog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTap() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        retryTimer = watchdog
    }

    private func checkTap() {
        guard AXIsProcessTrusted() else {
            // Revoked: drop the tap so a new grant gets a fresh one.
            if let tap { CFMachPortInvalidate(tap) }
            tap = nil
            return
        }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CFMachPortInvalidate(tap)
            self.tap = nil
            log.write("tap was off; reinstalling")
        }
        _ = installTap()
    }

    var isRunning: Bool { tap != nil }

    /// The recorder couldn't start: forget the press without acting on it.
    func resetGesture() {
        gesture.reset()
    }

    /// The recording hit its length cap (or the input device changed).
    func timeout() {
        let actions = gesture.timeout()
        log.write("  timeout -> \(actions)")
        actions.forEach(perform)
    }

    private func installTap() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            // The tap's run-loop source is on the main run loop.
            return MainActor.assumeIsolated { monitor.handle(type, event) }
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.write("tapCreate failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        log.write("tap installed")
        return true
    }

    // MARK: Recording a new shortcut (Settings)

    /// While capturing, every key goes to Settings instead of apps, and
    /// dictation is off. `done` gets the shortcut once all keys are released,
    /// or nil if Esc was pressed on its own.
    func capture(_ done: @escaping (Shortcut?) -> Void) {
        if gesture.recording { gesture.escape().forEach(perform) }
        capture = Capture(done: done)
    }

    func cancelCapture() { capture = nil }

    private struct Capture {
        let done: (Shortcut?) -> Void
        var modifiers: Modifiers = []
        var key: UInt16?
        var keyDown = false
    }

    private func captureEvent(_ type: CGEventType, _ event: CGEvent) {
        guard var c = capture else { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .flagsChanged:
            held = Modifiers(cgFlags: event.flags.rawValue)
            if c.key == nil { c.modifiers.formUnion(held) }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            if code == Self.escKeyCode && held.isEmpty && c.key == nil && c.modifiers.isEmpty {
                capture = nil
                c.done(nil)
                return
            }
            c.key = code
            c.modifiers = held
            c.keyDown = true
        case .keyUp:
            c.keyDown = false
        default:
            break
        }
        if held.isEmpty && !c.keyDown && (c.key != nil || !c.modifiers.isEmpty) {
            capture = nil
            c.done(Shortcut(modifiers: c.modifiers, keyCode: c.key))
        } else {
            capture = c
        }
    }

    // MARK: Events

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.write("tap re-enabled after \(type.rawValue)")
            // Events were missed while it was off: re-read which modifiers are held,
            // so a chord released meanwhile doesn't leave the recording running.
            held = Modifiers(cgFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
            if shortcut.isModifierOnly, chordDown, !shortcut.matches(held: held) {
                setChord(false, at: Self.ms(CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))))
            }
            return pass
        case .flagsChanged, .keyDown, .keyUp:
            if capture != nil {
                captureEvent(type, event)
                return nil
            }
            return type == .flagsChanged ? flagsChanged(event) : key(type, event)
        default:
            return pass
        }
    }

    private func flagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let raw = event.flags.rawValue
        let wasFn = held.contains(.fn)
        held = Modifiers(cgFlags: raw)
        let now = Self.ms(event.timestamp)
        // Timing log only while the shortcut is involved, not for everyday typing.
        if chordDown || gesture.recording {
            log.write("t=\(now) held=\(shortcutName(held))")
        }

        if shortcut.isModifierOnly {
            setChord(shortcut.matches(held: held), at: now)
        } else if chordDown && held.generic != shortcut.modifiers.generic {
            setChord(false, at: now)  // a modifier of a key shortcut came up
        }

        // Keep macOS's own fn action from firing after fn was part of a shortcut.
        if keyCode == Self.fnKeyCode && wasFn && !held.contains(.fn) && swallowFnRelease {
            swallowFnRelease = false
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func key(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let now = Self.ms(event.timestamp)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if let shortcutKey = shortcut.keyCode, code == shortcutKey {
            if type == .keyDown {
                if chordDown { return nil }  // auto-repeat while held
                if shortcut.matches(held: held, key: code) {
                    setChord(true, at: now)
                    return nil
                }
            } else if chordDown {
                setChord(false, at: now)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, !isRepeat else { return Unmanaged.passUnretained(event) }
        // Esc finishes a dictation (and stays out of the app).
        if code == Self.escKeyCode {
            let actions = gesture.escape()
            if !actions.isEmpty {
                log.write("  esc -> \(actions)")
                actions.forEach(perform)
                return nil
            }
        } else if chordDown {
            // Some other key while the shortcut is held: it was a different
            // shortcut (e.g. fn + Shift + arrow), not dictation.
            let actions = gesture.interrupt()
            if !actions.isEmpty {
                log.write("  other key -> \(actions)")
                actions.forEach(perform)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func setChord(_ down: Bool, at now: Int) {
        guard down != chordDown else { return }
        chordDown = down
        if down && shortcut.modifiers.contains(.fn) { swallowFnRelease = true }
        let actions = down ? gesture.press(at: now) : gesture.release(at: now)
        log.write("  chord \(down ? "down" : "up") -> \(actions)")
        actions.forEach(perform)
    }

    private func resetChord() {
        if gesture.recording { gesture.escape().forEach(perform) }
        chordDown = false
        swallowFnRelease = false
    }

    private func perform(_ action: KeyGesture.Action) {
        switch action {
        case .wait(let token):
            let delay = Double(gesture.doubleTapMs) / 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let actions = self.gesture.timerFired(token: token)
                    self.log.write("  timer \(token) -> \(actions)")
                    actions.forEach(self.perform)
                }
            }
        default:
            onAction(action)
        }
    }

    private func shortcutName(_ m: Modifiers) -> String {
        m.isEmpty ? "none" : Shortcut(modifiers: m).displayName
    }

    /// CGEvent timestamps are nanoseconds since boot.
    private static func ms(_ timestamp: CGEventTimestamp) -> Int { Int(timestamp / 1_000_000) }
}

/// Appends lines to a file in ~/Library/Logs/Loquor (timings only, never dictated
/// text). Written on a background queue; a file over 1 MB is started afresh.
struct KeyLog: Sendable {
    var name = "keys.log"

    private static let queue = DispatchQueue(label: "loquor.log", qos: .utility)
    private static let maxBytes: UInt64 = 1_000_000

    private static let dir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Loquor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func write(_ line: String) {
        let url = Self.dir.appending(path: name)
        let data = Data((ISO8601DateFormatter().string(from: .now) + " " + line + "\n").utf8)
        Self.queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
               size > Self.maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
