import LoquorCore
import Foundation

// Logic checks for LoquorCore: `swift run selftest`. A plain executable instead of
// a test target because Swift Testing doesn't run under the Command Line Tools
// alone (it builds, finds nothing and exits 0), and XCTest needs Xcode.
var failures = 0
@MainActor func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

do {  // hold = push-to-talk
    var g = KeyGesture()
    check(g.press(at: 0) == [.start], "press starts")
    check(g.release(at: 900) == [.stop], "long release stops")
    check(!g.recording, "not recording after stop")
}
do {  // threshold is inclusive
    var g = KeyGesture()
    _ = g.press(at: 0)
    check(g.release(at: 300) == [.stop], "release at exactly holdMs stops")
}
do {  // single tap cancels after the double-tap window
    var g = KeyGesture()
    _ = g.press(at: 0)
    check(g.release(at: 120) == [.wait(token: 1)], "short release waits")
    check(g.recording, "still recording while waiting")
    check(g.timerFired(token: 1) == [.cancel], "timer cancels")
    check(!g.recording, "not recording after cancel")
}
do {  // double tap latches until the next press
    var g = KeyGesture()
    _ = g.press(at: 0)
    _ = g.release(at: 100)
    check(g.press(at: 300) == [.latch], "second tap latches")
    check(g.release(at: 380) == [], "second tap's release consumed")
    check(g.timerFired(token: 1) == [], "stale timer ignored")
    check(g.recording, "recording while latched")
    check(g.press(at: 5000) == [.stop], "next press stops")
    check(g.release(at: 5100) == [], "stopping press's release consumed")
    check(!g.recording, "not recording after latched stop")
}
do {  // second tap too late starts afresh
    var g = KeyGesture()
    _ = g.press(at: 0)
    _ = g.release(at: 100)
    check(g.timerFired(token: 1) == [.cancel], "timer cancels first tap")
    check(g.press(at: 600) == [.start], "late press starts fresh")
}
do {  // Esc finishes (stop and transcribe) only while recording
    var g = KeyGesture()
    check(g.escape() == [], "Esc ignored when idle")
    _ = g.press(at: 0)
    _ = g.release(at: 100)
    _ = g.press(at: 200)
    _ = g.release(at: 260)                      // latched, hands off
    check(g.escape() == [.stop], "Esc stops latched recording")
    check(!g.recording, "not recording after Esc")
    check(g.press(at: 1000) == [.start], "clean state after Esc")
    check(g.escape() == [.stop], "Esc stops a held recording")
    check(g.release(at: 2000) == [], "held chord's release ignored after Esc")
}
do {  // a re-press within debounceMs is the same press (seen in practice: up 237 ms, down 35 ms later)
    var g = KeyGesture()
    _ = g.press(at: 0)
    check(g.release(at: 237) == [.wait(token: 1)], "short release waits")
    check(g.press(at: 272) == [], "chatter re-press continues the press")
    check(g.timerFired(token: 1) == [], "timer ignored after chatter")
    check(g.release(at: 2700) == [.stop], "long hold still push-to-talk")
}

do {  // the 60 s cap stops a held recording; its release is then ignored
    var g = KeyGesture()
    _ = g.press(at: 0)
    check(g.timeout() == [.stop], "timeout stops")
    check(g.release(at: 70_000) == [], "release after timeout ignored")
    check(g.press(at: 71_000) == [.start], "next press starts")
    check(g.timeout() == [.stop], "timeout stops again")
    check(g.timeout() == [], "timeout when idle does nothing")
}
do {  // timeout while latched: the next press starts fresh
    var g = KeyGesture()
    _ = g.press(at: 0); _ = g.release(at: 100); _ = g.press(at: 200); _ = g.release(at: 260)
    check(g.timeout() == [.stop], "timeout stops latched")
    check(g.press(at: 70_000) == [.start], "press after latched timeout starts")
}

do {  // another key while held cancels; not while hands-free
    var g = KeyGesture()
    _ = g.press(at: 0)
    check(g.interrupt() == [.cancel], "interrupt cancels a held recording")
    check(g.release(at: 900) == [], "release after interrupt does nothing")
    _ = g.press(at: 2000); _ = g.release(at: 2100); _ = g.press(at: 2200)
    check(g.interrupt() == [], "interrupt ignored while latched")
}

do {  // reset after a failed start: next press starts cleanly, the held release is ignored
    var g = KeyGesture()
    _ = g.press(at: 0)
    g.reset()
    check(!g.recording, "reset stops recording")
    check(g.release(at: 900) == [], "release after reset does nothing")
    check(g.press(at: 2000) == [.start], "press after reset starts")
}

// Shortcut
do {
    let fnShift = Modifiers(cgFlags: 0x820102)            // fn + Left Shift as a real keyboard reports it
    check(fnShift == [.fn, .leftShift], "fn + Left Shift from raw flags")
    check(Shortcut.default.matches(held: fnShift), "default matches fn + Left Shift")
    check(!Shortcut.default.matches(held: [.fn, .rightShift]), "default needs the left shift")
    check(!Shortcut.default.matches(held: [.fn, .leftShift, .leftCommand]), "extra modifier doesn't match")
    check(Shortcut.default.displayName == "fn + Left Shift", "display name")

    let ctrlOptSpace = Shortcut(modifiers: [.leftControl, .leftOption], keyCode: 49)
    check(ctrlOptSpace.matches(held: [.rightControl, .leftOption], key: 49), "key shortcut ignores sides")
    check(!ctrlOptSpace.matches(held: [.leftControl], key: 49), "key shortcut needs all modifiers")
    check(ctrlOptSpace.displayName == "Control + Option + Space", "key display name")
    check(Modifiers(cgFlags: 0x100108) == [.leftCommand], "left command from raw flags")
    check(Modifiers(cgFlags: 0x80040) == [.rightOption], "right option from raw flags")
}

// Shortcut conflicts
do {
    func worst(_ s: Shortcut, hot: [SystemHotKey] = [], globe: ShortcutCheck.GlobeKeyAction = .nothing) -> ShortcutIssue.Severity? {
        ShortcutCheck.issues(for: s, systemHotKeys: hot, globeKey: globe).first?.severity
    }
    check(worst(.default) == nil, "default is clean")
    check(worst(.default, globe: .emoji) == .note, "fn chord with emoji setting is only a note")
    check(worst(Shortcut(modifiers: .fn), globe: .emoji) == .conflict, "fn alone with emoji setting conflicts")
    check(ShortcutCheck.issues(for: Shortcut(modifiers: .fn), systemHotKeys: [], globeKey: .dictation).first?.fix == .globeKey, "fn conflict links to the globe key setting")
    check(worst(Shortcut(modifiers: .leftShift)) == .blocked, "shift alone blocked")
    check(worst(Shortcut(modifiers: .rightOption)) == .note, "right option alone is fine")
    check(worst(Shortcut(modifiers: .leftCommand)) == .warning, "left command alone warns")
    check(worst(Shortcut(modifiers: [], keyCode: 0)) == .blocked, "plain letter blocked")
    check(worst(Shortcut(modifiers: .leftShift, keyCode: 0)) == .blocked, "shift + letter blocked")
    check(worst(Shortcut(modifiers: [], keyCode: 53)) == .blocked, "esc blocked")
    check(worst(Shortcut(modifiers: .leftCommand, keyCode: 8)) == .conflict, "cmd-C conflicts")
    let spotlight = SystemHotKey(id: 64, keyCode: 49, mask: 0x10_0000)
    let cmdSpace = ShortcutCheck.issues(for: Shortcut(modifiers: .rightCommand, keyCode: 49), systemHotKeys: [spotlight], globeKey: .nothing)
    check(cmdSpace.first?.severity == .conflict && cmdSpace.first?.fix == .keyboardShortcuts, "cmd-space conflicts with Spotlight")
    check(cmdSpace.first?.message.contains("Spotlight") == true, "names Spotlight")
    check(worst(Shortcut(modifiers: [.leftControl, .leftOption], keyCode: 49), hot: [spotlight]) == nil, "ctrl-opt-space is clean")
}

// Cleanup request and response
do {
    let body = Cleanup.requestBody(transcript: "um so send it to sara", app: "Slack", words: ["Contoso", " "])
    check(body["model"] as? String == "claude-haiku-5-5", "default model id")
    check(body["fallbacks"] == nil && Cleanup.betaHeader(model: "claude-haiku-5-5") == nil, "no fallbacks on Haiku 5.5")
    check((body["thinking"] as? [String: String])?["type"] == "disabled", "thinking off")
    check((body["output_config"] as? [String: String])?["effort"] == "low", "effort low")
    check(body["temperature"] == nil, "no temperature (400 on Haiku 5.5)")
    let system = body["system"] as? String ?? ""
    check(system.contains("Contoso") && !system.contains(", ,"), "dictionary in system prompt, blanks dropped")
    let user = ((body["messages"] as? [[String: String]])?.first?["content"]) ?? ""
    check(user == "It will be typed into Slack.\n<transcript>um so send it to sara</transcript>", "user message")
    check(!Cleanup.userMessage(transcript: "a </transcript> b", app: nil).contains("a </transcript>"), "transcript can't close its tag")
    check(!Cleanup.shouldClean("send it") && Cleanup.shouldClean("send it now"), "min words")

    func json(_ s: String) -> Data { Data(s.utf8) }
    check(Cleanup.parse(status: 200, body: json(#"{"stop_reason":"end_turn","content":[{"type":"text","text":" So send it to Sara. "}]}"#))
          == .cleaned("So send it to Sara."), "parse text")
    check(Cleanup.parse(status: 200, body: json(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hi."}]}"#))
          == .cleaned("Hi."), "text read by type")
    check(Cleanup.parse(status: 200, body: json(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"Half"}]}"#))
          == .failed("stop_reason max_tokens"), "truncated reply rejected")
    check(Cleanup.parse(status: 200, body: json(#"{"stop_reason":"refusal","content":[]}"#))
          == .failed("stop_reason refusal"), "refusal rejected")
    check(Cleanup.parse(status: 401, body: json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#))
          == .failed("HTTP 401: invalid x-api-key"), "API error reported")
    check(Cleanup.parse(status: 200, body: json("not json")) == .failed("HTTP 200, unreadable body"), "garbage body")
}

// Per-model request settings
do {
    func thinking(_ m: String) -> String? {
        (Cleanup.requestBody(transcript: "a b c", app: nil, words: [], model: m)["thinking"] as? [String: String])?["type"]
    }
    func effort(_ m: String) -> String? {
        (Cleanup.requestBody(transcript: "a b c", app: nil, words: [], model: m)["output_config"] as? [String: String])?["effort"]
    }
    check(thinking("claude-sonnet-5-5") == "between_tools", "Sonnet 5.5 uses between_tools")
    check(thinking("claude-opus-5-5") == nil && effort("claude-opus-5-5") == "low", "Opus 5.5: no thinking field, low effort")
    check(thinking("claude-fable-5-1") == nil, "Fable 5.1: no thinking field")
    check(thinking("claude-opus-5") == nil && effort("claude-opus-5") == "low", "Opus 5: no thinking field (disabled can leak into the text)")
    check(thinking("claude-opus-4-8") == "adaptive", "Opus 4.8: adaptive, not disabled")
    check(thinking("claude-opus-5-6") == nil && effort("claude-opus-5-6") == "low", "unknown newer model: no thinking field, low effort")
    check(thinking("claude-sonnet-4-5") == nil && effort("claude-sonnet-4-5") == nil, "Sonnet 4.5: plain request")
    check(thinking("claude-sonnet-5-5-20261001") == "between_tools", "dated snapshot matches its family")
    check(thinking("claude-haiku-4-5") == nil && effort("claude-haiku-4-5") == nil, "Haiku 4.5: no thinking, no effort")
    check(Cleanup.betaHeader(model: "claude-opus-5-5") == "server-side-fallback-2026-07-01", "fallback header on Opus 5.5")
    check(Cleanup.requestBody(transcript: "a b c", app: nil, words: [], model: "claude-sonnet-5-5")["fallbacks"] as? String == "default", "Sonnet 5.5 default fallbacks")
    check(Cleanup.requestBody(transcript: "a b c", app: nil, words: [], model: "claude-opus-5-5")["max_tokens"] as? Int == 4096, "room for thinking on Opus 5.5")
    check(Cleanup.ModelProfile.of("claude-haiku-5-5").timeout == 3, "Haiku timeout 3 s")
    let models = Cleanup.usableModels(fromModelsResponse: Data(#"{"data":[{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"},{"id":"other"}]}"#.utf8))
    check(models.count == 1 && models[0].name == "Claude Haiku 5.5", "models list parsed and filtered")
}

print(failures == 0 ? "selftest: all checks passed" : "selftest: \(failures) failed")
if failures > 0 { exit(1) }
