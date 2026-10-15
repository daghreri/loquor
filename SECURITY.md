# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's
[security advisories](../../security/advisories/new) rather than a public issue.

## What Loquor sends and stores

- **Audio** is recorded only while the shortcut is in use, transcribed on the
  Mac, and never saved or sent.
- **With cleanup off**, nothing about your dictation leaves the Mac. The only
  network use is the one-time speech model download from Hugging Face
  (`huggingface.co`), skipped by the offline build.
- **With cleanup on**, each dictation's transcript, the name of the frontmost app
  and your word list go to `api.anthropic.com` over HTTPS with your API key.
- **The API key** is kept only in the login Keychain (not synced), read at most
  once per launch, and kept in memory while Loquor runs. It's never written to
  files, preferences or logs.
- **Settings** (shortcut, model, word list) are in
  `~/Library/Preferences/com.daghreri.loquor.plist`, not encrypted.
- **Logs** in `~/Library/Logs/Loquor/` hold timings while the shortcut is in use
  and error reasons, never dictated text. Each file is capped at 1 MB.
- The speech model is pinned to one Hugging Face commit and verified by FluidAudio
  before use.
