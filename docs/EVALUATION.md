# Evaluation protocol

Jarvis separates automated contract verification from hardware-dependent product evaluation. Results should always identify which category produced the evidence.

## Automated verification

Run:

```bash
./scripts/verify.sh
```

The suite verifies:

- deterministic and model-planned routing;
- action allowlists, payload validation, grounding, and risk classification;
- transcript preview and confirmation contracts;
- financial execution rejection;
- memory search, correction, privacy, migration, export, and backup behavior;
- dashboard token, origin, host, cookie, and request-size controls;
- desktop handoff retries and clear permission errors;
- named-window capture isolation and no active-window fallback;
- speaker-profile comparison logic and raw-audio retention policy;
- resource-aware model selection and idle release;
- TradingView capture ordering and mandatory state restoration;
- native bundle, signing, App Intent, wake-listener, and HUD source contracts.

CI runs the same Python/source-contract suite with `ResourceWarning` promoted to an error and scans the repository for private paths, credentials, generated data, and oversized artifacts.

## Manual macOS verification

Use a non-production test account or back up the existing Jarvis data first.

### Voice

1. Verify the selected input device in **Jarvis Status**.
2. Test five near-field commands in a quiet room.
3. Repeat with normal background television audio.
4. Test an utterance with a known pronunciation variation.
5. Confirm recording ends after speech and does not remain active on room audio.
6. Say only `Siri`; confirm Jarvis releases the microphone and resumes afterward.
7. With Owner Voice enabled, record owner accept/reject and non-owner reject counts. Never publish raw recordings.

Suggested metrics:

- wake-word false reject rate;
- non-owner false accept rate;
- command intent accuracy;
- median end-of-speech to transcript-preview latency;
- percentage of sessions that recover without restarting the app.

### Screen capture and UI automation

1. Confirm the installed app has Screen Recording and Accessibility permission.
2. Capture a named background application and verify no active-window substitution occurred.
3. Run one TradingView scan with the expected two-chart layout.
4. Confirm four real images exist and correspond to 5m, 15m, 1h, and 4h.
5. Confirm the final chart interval is 5m and both Interval and Date Range synchronization are off.
6. Force a mid-sequence failure and verify cleanup still runs.

### Presence and performance

1. Use **Preview Jarvis Presence** to play the full state sequence.
2. Check geometry at standby and expanded sizes.
3. Observe animation smoothness, reduced-motion behavior, and multi-display placement.
4. Sample the complete process tree, not only the HUD process.
5. Record idle and active CPU/RSS, macOS thermal state, hardware, OS build, and sampling duration.

Do not turn one point-in-time measurement into a universal benchmark. Publish the measurement method beside every number.

## Release gate

A source release is eligible when:

- automated verification passes from a clean checkout;
- the public secret/privacy scan passes;
- source and generated artifact sizes are reviewed;
- third-party model revisions and notices are current;
- manual voice, capture, cleanup, and presence checks have dated evidence;
- no binary is attached unless Developer ID signing and notarization are verified.
