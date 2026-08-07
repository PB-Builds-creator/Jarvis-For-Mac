# Troubleshooting

## Build fails before Swift compilation

Confirm Python 3.11+ and the Apple Command Line Tools:

```bash
python3 --version
swiftc --version
xcrun --sdk macosx --show-sdk-path
```

Every optional helper currently requires a toolchain containing the macOS 26 SDK. Use `JARVIS_VERIFICATION_BUILD=1` to verify the native build without downloading model weights.

## Screen Recording appears enabled but capture fails

Permission must belong to the exact installed bundle identity. Choose **Check Screen Permission** only when deliberately testing capture. If a real ScreenCaptureKit capture is denied, toggle Jarvis off and on once under **System Settings → Privacy & Security → Screen & System Audio Recording**, then fully quit and reopen the same installed app.

Jarvis does not repeatedly request permission at launch. A preflight API alone does not prove capture works.

## Named-app capture fails

The requested application must already be open and have a normal visible window. Jarvis intentionally does not substitute the active window when a named background-window capture fails.

## Wake word or transcription is unreliable

1. Open **Jarvis Status** and note the actual input device.
2. Use **Restart Voice Listener** once.
3. If an external microphone was connected or disconnected, wait for the route refresh.
4. Test with **Talk to Jarvis** before evaluating the wake word.
5. Use **Teach Jarvis a Pronunciation…** for a stable recurring phrase error.
6. Check `voice-health` for the most recent failure and recovery evidence.

Background speech can keep raw audio active without producing a valid transcript; the unrecognized-audio deadline should still return the app to idle.

## Siri does not hear the microphone

A standalone leading `Siri` should make Jarvis release its audio session, launch Siri, and resume afterward. If the Jarvis HUD remains active, restart the voice listener and retest the standalone word rather than a sentence containing `Siri` in the middle.

## Owner Voice repeatedly rejects the owner

Confirm the intended microphone is active and test a normal speaking voice at the enrollment distance. Re-enrollment requires Touch ID and replaces the numeric profile; Jarvis never silently learns from failed wake attempts. Owner Voice is not designed as strong anti-replay authentication.

## Desktop reasoning handoff fails

The desktop adapter requires a locally installed and signed-in ChatGPT or Codex desktop app. A socket path can exist before its listener is ready; Jarvis retries briefly, then returns a clear error. Desktop application updates can require adapter maintenance.

## TradingView scan fails or leaves changed controls

Use the expected two-chart window and visible semantic labels. On completion or failure, verify the interval is 5m and both **Interval** and **Date Range** synchronization are off. Do not treat a missing screenshot as an analysis result.

## Dashboard will not open

The dashboard is tied to the menu app's process and ephemeral token. Restart the Jarvis core from the menu rather than bookmarking the loopback URL.
