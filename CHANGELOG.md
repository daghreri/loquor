# Changelog

## 0.1.1

- **Indicator on the right display:** it now appears on the display you're typing on (it
  followed the mouse, so with two displays it often seemed missing over full-screen apps),
  and stays above full-screen apps and videos.
- **Microphone:** the menu bar and Settings show the microphone in use; pick one, or System
  Default, which follows macOS (AirPods in, built-in mic out). Fixed AirPods recording
  silence, dictation ending about a second in after a mic switch, and a "-10868" error.
- **Longest dictation:** 1 minute by default, up to 3 minutes in Settings. Hands-free stops
  by itself after 20 seconds of silence and types what you said.
- **Cleanup** gets more time for longer dictations.
- **Update alerts:** Loquor checks GitHub once a day and shows "Download Update" in the
  menu when there's a new release (can be turned off in Settings › About).

## 0.1.0

First public release.

- Hold-to-talk and hands-free dictation into any app, with a shortcut you choose
  (default fn + Left Shift) and conflict checks against macOS and common app shortcuts.
- On-device speech recognition with NVIDIA Parakeet TDT 0.6B v2 (Core ML, Apple
  Neural Engine).
- Floating indicator with waveform and timer; 60-second limit with a countdown.
- Optional cleanup with Claude using your own API key; any model your key can use,
  Claude Haiku 5.5 by default. Falls back to the raw transcript on any problem
  or when offline.
- Copy Last Dictation and Retry Last Dictation in the menu.
- Standard (model downloads on first launch) and offline (model included) builds.
