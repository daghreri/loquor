# Changelog

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
