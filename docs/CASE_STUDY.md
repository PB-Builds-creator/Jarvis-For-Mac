# Case study: building a useful local-first macOS agent

## Problem

Most desktop assistant demos optimize for the happy path: transcribe a command, send it to a model, and execute the answer. A daily-use assistant has a harder job. It must share a microphone with Siri, understand imperfect speech over background media, survive permission and application changes, protect private data, keep the Mac responsive, and never confuse a plausible plan with a completed action.

Jarvis began as a small voice-to-desktop bridge and evolved through real failures into a layered local-first agent.

## Product constraints

- No paid model API is required for the current workflow.
- The always-on path must not keep a large model or visual pipeline resident.
- Background television and conversation are normal operating conditions.
- A connected external microphone is preferred without changing output devices.
- Siri and Jarvis must coexist and release the microphone to one another.
- Any consequential local action must remain visible and confirmable.
- Financial analysis must never become trade execution.
- The system must remain useful when local models, desktop handoff, or permissions are unavailable.

## Key engineering decisions

### 1. Separate proposals from authority

Model output never directly controls the Mac. Every proposal is parsed into a typed allowlist, grounded against the spoken request, assigned a risk tier, previewed, and executed by deterministic code. The executor validates preconditions and postconditions and stops the remaining sequence after the first failure.

### 2. Route by capability and cost

Common commands skip model inference entirely. Apple Foundation Models and Qwen 4B cover lightweight local work. Qwen 9B is reserved for multi-step requests where extra reasoning is useful and the machine has adequate memory, battery, and thermal headroom. Deep visual or implementation work uses a desktop reasoning adapter.

### 3. Design speech for a noisy room

The voice pipeline combines native on-device transcription, command vocabulary, whole-utterance intent matching, low-cost acoustic endpointing, transcript-stability timers, and an on-demand Whisper recovery path. Silence and unrecognized room audio have separate deadlines so an active television cannot hold recording open indefinitely.

### 4. Treat identity as layered evidence

Owner Voice uses five enrollment samples and 256-dimensional WeSpeaker embeddings. It checks both a centroid and multiple references, treats pitch only as secondary evidence, deletes raw recordings, and stores the numeric profile through Keychain. Touch ID still protects profile changes and credentials.

### 5. Make workflow cleanup part of correctness

The four-timeframe TradingView capture temporarily changes two synchronization controls. Restoration to 5m with Interval and Date Range off runs as a required cleanup path, including partial failures. The scan fails closed when it cannot obtain a real capture.

## Failures that shaped the system

| Failure observed | Root cause | Engineering response |
|---|---|---|
| Desktop handoff socket existed but rejected the first connection | file existence was not listener readiness | bounded connect retry with a clear terminal error |
| macOS showed Screen Recording enabled but capture still failed | stale permission identity or replaced ad-hoc binary | verify real ScreenCaptureKit output; keep a stable installed identity; never prompt repeatedly at launch |
| Wake listener blocked Siri | both assistants competed for the input session | detect standalone `Siri`, tear down Jarvis audio, launch Siri, resume afterward |
| Recording continued over background media | acoustic activity did not imply usable speech | separate transcript inactivity, hard-stop, and unrecognized-audio timers |
| Slight mispronunciation missed a known command | literal keyword matching discarded context | bounded command-catalog recovery using full utterance and active app |
| “Open TradingView” became a reasoning proposal | simple navigation was routed through a model | deterministic app-only fast path |
| Owner voice rejected normal far-field speech | one threshold overfit clean enrollment audio | multi-reference tolerant tier without silently weakening non-owner rejection |
| A failed multi-step UI action could leave later actions running | no transactional boundary | preconditions, checkpoints, stop-on-failure, receipts, and cleanup guarantees |

## Result

The public source snapshot contains approximately 23,000 lines of implementation across Swift and Python and 186 automated tests. The system includes native voice and screen pipelines, local model routing, structured memory, App Intents, privacy controls, transactional actions, and a domain-specific evidence workflow.

The test count is not presented as proof of voice accuracy or production readiness. It is evidence that critical policies and failure paths are encoded and repeatable. Real microphone, permission, ScreenCaptureKit, and animation behavior remain part of the manual evaluation protocol.

## What I would improve next

1. Split the native application into testable feature modules and add XCTest UI-independent targets.
2. Build a consented, privacy-safe replay corpus for wake words, noisy-room commands, and non-owner rejection.
3. Define a stable provider interface for deep reasoning transports.
4. Add signed release provenance, SBOM generation, Developer ID signing, and notarization.
5. Turn domain workflows into declarative capability packs instead of compiled special cases.

## Interview discussion prompts

- Why does grounding a model-generated path against the user's transcript matter?
- Which state belongs in memory, and which state should expire with a session?
- How do you measure voice recognition without storing private raw audio?
- What makes cleanup a transaction invariant rather than a best-effort step?
- When is a larger local model worth its memory and latency cost?
- Which claims are covered by automated tests, and which require hardware evidence?
