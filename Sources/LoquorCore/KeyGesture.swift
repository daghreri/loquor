import Foundation

/// Turns presses and releases of the dictation chord into dictation actions.
/// Pure logic (times are passed in) so it can be tested without a keyboard.
///
///   hold >= holdMs              push-to-talk: record while held, transcribe on release
///   tap, second press within    hands-free: keep recording until the next press
///     doubleTapMs of release
///   single short tap            cancel: nothing is typed
///   Esc while recording         stop and transcribe
///   re-press within debounceMs  same press (key chatter or a finger settling)
///
/// Recording starts on the first press so a hold doesn't lose its first words.
public struct KeyGesture {
    public enum Action: Equatable, Sendable {
        case start              // begin recording
        case latch              // recording continues hands-free
        case stop               // stop and transcribe
        case cancel             // stop and discard
        case wait(token: Int)   // call timerFired(token:) after doubleTapMs
    }

    public var holdMs: Int
    public var doubleTapMs: Int
    public var debounceMs: Int

    public private(set) var recording = false
    private var latched = false
    private var consumeRelease = false
    private var pressedAt = 0
    private var pending: (token: Int, at: Int)?
    private var nextToken = 0

    public init(holdMs: Int = 300, doubleTapMs: Int = 400, debounceMs: Int = 60) {
        self.holdMs = holdMs
        self.doubleTapMs = doubleTapMs
        self.debounceMs = debounceMs
    }

    public mutating func press(at t: Int) -> [Action] {
        if latched {
            // Press while hands-free: finish; ignore this press's release.
            latched = false
            consumeRelease = true
            recording = false
            return [.stop]
        }
        if let p = pending, t - p.at < debounceMs {
            // Released and pressed again almost at once (seen in practice: 35 ms):
            // the same press continues; its hold time still counts from the first press.
            pending = nil
            return []
        }
        if let p = pending, t - p.at < doubleTapMs {
            // Second tap: keep the same recording going.
            pending = nil
            latched = true
            consumeRelease = true
            return [.latch]
        }
        pending = nil
        pressedAt = t
        recording = true
        return [.start]
    }

    public mutating func release(at t: Int) -> [Action] {
        if consumeRelease {
            consumeRelease = false
            return []
        }
        guard recording, !latched else { return [] }
        if t - pressedAt >= holdMs {
            recording = false
            return [.stop]
        }
        // Short tap: wait for a possible second tap.
        nextToken += 1
        pending = (nextToken, t)
        return [.wait(token: nextToken)]
    }

    public mutating func timerFired(token: Int) -> [Action] {
        guard pending?.token == token else { return [] }
        pending = nil
        recording = false
        return [.cancel]
    }

    /// Another key was pressed while the shortcut was held (e.g. fn + Shift + arrow
    /// to select text): that was a shortcut, not dictation, so throw it away.
    public mutating func interrupt() -> [Action] {
        guard recording, !latched else { return [] }
        recording = false
        pending = nil
        return [.cancel]
    }

    /// Forget any recording in progress without producing an action (the
    /// recorder failed to start, so there's nothing to stop or cancel).
    public mutating func reset() {
        recording = false
        latched = false
        pending = nil
        consumeRelease = false
    }

        /// Recording hit the length cap: stop and transcribe what there is.
    public mutating func timeout() -> [Action] { finish() }

    /// Esc: stop and transcribe, same as the stopping press. Returns [] when not
    /// recording, so the key can pass through to the app.
    public mutating func escape() -> [Action] { finish() }

    /// Stops and transcribes from any recording state. If the chord is still
    /// held, its coming release is ignored.
    private mutating func finish() -> [Action] {
        guard recording else { return [] }
        consumeRelease = !latched && pending == nil
        recording = false
        latched = false
        pending = nil
        return [.stop]
    }
}
