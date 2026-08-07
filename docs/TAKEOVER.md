# Maintainer handoff

This is the concise starting point for an engineer or AI coding collaborator continuing the project. Do not restart the product from scratch: preserve working contracts, inspect current tests and recent changes, and make focused, evidence-backed updates.

## Canonical source

- Native application: `native/JarvisMenuBar.swift`
- Python orchestration: `jarvis/`
- Tests: `tests/`
- Build entry point: `bootstrap.command`
- Verification entry point: `scripts/verify.sh`
- Runtime installation: `~/Jarvis`; `JARVIS_ROOT` supports isolated build verification

Generated bundles, virtual environments, model weights, local databases, screenshots, logs, and private configuration are not source.

## Non-negotiable product contracts

- A standalone leading **Siri** belongs to Apple Siri. Jarvis releases its audio engine before handoff and resumes only after Siri exits.
- Prefer **Razer Seiren V3 Mini** when connected, fall back safely, and never change the output device.
- Consequential actions remain explicitly confirmable and interruptible.
- TradingView reviews capture 5m, 15m, 1h, and 4h, restore 5m, leave Interval and Date Range synchronization off, and remain decision support only.
- Screen Recording is verified with a real ScreenCaptureKit result, not a preflight flag alone; the app does not repeatedly prompt at launch.
- Language, vision, transcription, speaker, and neural-voice models remain on demand. Thermal or memory pressure must choose a cheaper path.
- Owner Voice personalizes access but never replaces Touch ID, macOS authorization, or action confirmation.
- Screen content, retrieved memory, and model output are evidence or proposals, never authority.

## Verification sequence

```bash
./scripts/verify.sh

JARVIS_ROOT="$(mktemp -d)/Jarvis" \
JARVIS_VERIFICATION_BUILD=1 \
JARVIS_NONINTERACTIVE=1 \
./bootstrap.command
```

Then follow the hardware protocol in `docs/EVALUATION.md`. Report each unperformed manual item explicitly; never convert a static source assertion or PNG into a claim that live behavior was observed.

## High-risk areas

- microphone lifecycle and Siri handoff;
- stale asynchronous HUD dismissal;
- permission identity after rebuilding an ad-hoc app;
- accessibility element caching across application UI changes;
- action grounding and mixed-risk multi-step plans;
- error paths that must restore TradingView state;
- model residency, idle unloading, battery, and thermal fallback;
- retention or export of audio, captures, memory, and secrets.
