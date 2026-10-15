# How Loquor works

## Pipeline

```
shortcut ─► KeyMonitor ─► KeyGesture ─► Recorder ─► Transcriber ─► (Cleanup) ─► Paster
 (CGEventTap)  (hold / double-tap / tap)  (AVAudioEngine)  (Parakeet, Core ML)  (Claude, optional)  (clipboard + ⌘V)
```

- **KeyMonitor** (`Sources/Loquor/KeyMonitor.swift`) watches the shortcut through a
  `CGEventTap` (needs Accessibility). The shortcut is "pressed" when exactly its
  modifiers (and key, if any) are down. Any other key while it's held cancels,
  so shortcuts like fn + Shift + arrow still select text. After the shortcut,
  fn's own action (emoji picker, macOS dictation) is suppressed.
- **KeyGesture** (`Sources/LoquorCore`) is the state machine: hold ≥ 300 ms is
  push-to-talk; a second press within 400 ms of a short release latches
  hands-free; a single short tap cancels; Esc or the 60 s cap finish; a
  re-press within 60 ms is key chatter. Recording starts on the first press so
  no words are lost.
- **Recorder** uses a fresh `AVAudioEngine` per recording at the input's native
  rate, so the microphone indicator is on only while dictating. If the input
  device changes mid-recording, it finishes with what it has.
- **Transcriber** runs NVIDIA Parakeet TDT 0.6B v2 through FluidAudio on the
  Apple Neural Engine, loaded once at launch. Audio is resampled to 16 kHz once
  at the end. Release to text is about 100–150 ms on an M-series Mac.
- **Cleanup** (optional) sends the transcript to the Anthropic Messages API. Each
  model family gets its lowest-latency accepted settings
  (`Cleanup.ModelProfile`). Only a complete `end_turn` reply is used; anything
  else, a timeout, or being offline types the raw transcript.
- **Paster** saves the clipboard, pastes with ⌘V (never Return), and restores the
  clipboard after a second unless something else changed it. The last dictation
  stays in the menu for **Copy Last Dictation**; audio that failed to transcribe
  stays for **Retry Last Dictation**.

## Where things live

| | |
|---|---|
| Speech model | Pinned to Hugging Face commit `ee09c569…` of `FluidInference/parakeet-tdt-0.6b-v2-coreml`. Inside the app for the offline build, otherwise downloaded once to `~/Library/Application Support/Loquor/Models`. |
| API key | Login Keychain, service `com.daghreri.loquor`. Read silently during dictation; if macOS would ask, the text is typed as heard and Settings shows an approval step. |
| Settings | `UserDefaults` (`com.daghreri.loquor`). |
| Logs | `~/Library/Logs/Loquor/`: timings while the shortcut is in use and error reasons; never text; 1 MB cap. |

## Decisions

- **FluidAudio over parakeet-mlx.** Same model and accuracy; FluidAudio was 2–3×
  faster warm (35–80 ms vs 63–221 ms for 1–22 s clips), used ~100 MB instead of
  1.3 GB, and needs no bundled Python.
- **Paste, don't type.** Synthesising every keystroke is slow and breaks on
  keyboard layouts; ⌘V with the clipboard restored is reliable.
- **No Xcode required.** SwiftPM builds the app; scripts assemble and sign the
  bundle. Logic checks run as `swift run selftest` because Swift Testing doesn't
  run under the Command Line Tools alone.
- **Stable signing.** macOS ties Microphone and Accessibility permissions (and
  Keychain access) to the app's signature, so development builds use a local
  self-signed identity (`scripts/make-dev-cert.sh`) and releases a Developer ID
  (`docs/releasing.md`).
- **Shortcut checks.** `ShortcutCheck` compares a new shortcut with macOS's own
  shortcuts (`com.apple.symbolichotkeys`, defaults included since the file only
  stores changes), the 🌐/fn key setting, and common app shortcuts.
