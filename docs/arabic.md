# Arabic dictation (parked)

Status, 2026-10-19: **built and working, on hold for a better model.** Not in a release.

## What works

- **Opt-in:** Settings › General › Languages › Arabic. Off by default; while off, the
  keyboard layout is ignored and everything is English.
- **The keyboard layout picks the language:** an Arabic layout means an Arabic dictation,
  anything else English. Decided when you let go, so switching layouts mid-sentence
  fixes a mistake.
- **The indicator shows "English" / "عربي"**, updating live.
- **Model download:** pinned Hugging Face commit, SHA-256 checked, progress in Settings,
  Remove button.
- **Cleanup:** Arabic rules (keep the dialect, Arabic punctuation, ة and hamza, English
  words written back in English).

## Why it's parked

The speech model isn't accurate enough yet. Cohere Transcribe 03-2026 was the best open
model we tested (about 20% word error rate on Saudi dialect and MSA, against about 30% for
Whisper large-v3-turbo), but real use still wasn't good enough. Mixed Arabic/English
sentences are the weakest (about 59%).

On the CPU and Neural Engine it costs about 200 MB and 1.5 s per dictation. Letting Core
ML use the GPU costs about 10 GB more ([FluidAudio#1045](https://github.com/FluidInference/FluidAudio/issues/1045)).

## Resuming

1. Score new candidate models on the same Arabic test set (kept privately; contact the
   maintainer).
2. If one is clearly better, swap it in `Sources/Loquor/ArabicSupport.swift` (repo,
   revision, file list, transcriber) and re-test on real dictation.
3. Rebase this branch on main, update the README, NOTICE (model credit) and CHANGELOG,
   then release.

Candidates to watch: newer Cohere Transcribe releases, a Whisper successor with open
weights, NVIDIA's Arabic FastConformer once there's a Core ML port, and Saudi-dialect
fine-tunes.
