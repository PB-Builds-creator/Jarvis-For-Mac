# Jarvis Presence System

This document is the handoff source of truth for Jarvis's animated top-right
presence. Read it before changing the HUD lifecycle, voice-state routing, or
animation layers.

## Product intent

The presence should feel like one conscious local intelligence living on the
Mac, not a loading spinner and not a collection of unrelated overlays. It is a
quiet, compact orb while Jarvis is available and expands in place when Jarvis
is listening, reasoning, observing, speaking, or rejecting an unverified voice.
It must never obscure the user's work more than necessary.

The user explicitly wants the top-right animation to be prominent and
cinematic. The default is therefore persistent, but the menu item **Keep Jarvis
Presence Visible** disables the ambient form without disabling voice features.

## Active implementation

All implementation is currently in `native/JarvisMenuBar.swift`:

- `JarvisPresenceState` defines semantic states, labels, colors, and panel size.
- `JarvisPresenceView` owns the Core Animation layer hierarchy and motion.
- `JarvisPresenceHUDController` owns the non-activating panel, top-right
  placement, compact/expanded transitions, preview sequence, and dismissal
  generation.
- `JarvisMenuController` maps real voice/capture lifecycle events to the HUD.
- `renderPresencePreview(state:)` renders deterministic PNGs for visual QA.

Do not introduce another animated status-item view. `JarvisEnergyOrbView` is
legacy reference code and is intentionally never attached. A single visual
owner prevents the old bug where a menu-bar spinner survived after the main HUD
finished.

## State contract

| State | Label | Color family | Motion meaning |
| --- | --- | --- | --- |
| `standby` | AWAKE | cyan/blue | compact, slow asynchronous breathing |
| `awakening` | ONLINE | cyan/blue | ignition and focus |
| `listening` | LISTENING | blue/teal | strongest receptive signal ring |
| `thinking` | REASONING | purple/pink | faster counter-rotation and neural activity |
| `speaking` | RESPONDING | green/cyan | fastest breathing and waveform energy |
| `capturing` | OBSERVING | orange/yellow | dominant scanning sweep |
| `rejected` | VOICE NOT VERIFIED | red/orange | brief contraction/shake; owner lock remains closed |

Voice and capture call sites must use these states rather than inventing visual
timers. `dismiss()` returns to `standby` when ambient presence is enabled.
`hide()` is reserved for system sleep and Siri handoff.

## Layer hierarchy (second generation)

The view uses only compositor-friendly layers:

1. radial backdrop and breathing spectral halo;
2. sparse field, horizon grid, and a replicated 36-ray corona;
3. segmented orbital rings and four independently traced data arcs;
4. conic observation sweep and expanding pulse replicator;
5. two morphing energy membranes plus primary and echo neural paths;
6. primary and echo radial signal paths with state-specific modulation;
7. three tilted gyroscope planes with independent counter-rotation;
8. enlarged masked core with six drifting plasma gradients and a rotating
   spectral lens;
9. independently focusing pupil, iris, moving glint, replicated photon stream,
   and orbiting sparks;
10. text labels that provide a non-color state cue.

Non-commensurate durations make the orb feel organic without randomness,
per-frame drawing, or background inference. Paths are generated only during
layout or state configuration. Point-compatible membrane and waveform paths
are precomputed, then morphed by Core Animation on the render server. Core
Animation owns every continuous frame after configuration.

## Performance and accessibility invariants

- Never add a permanent `Timer`, display link, Metal render loop, continuous
  OCR, or continuous model inference for this UI.
- Expanded-only corona, photon, gyroscope, ribbon, echo, lens, and telemetry
  layers are hidden and receive no animations in compact standby.
- Prefer one replicated source layer over many independently managed particle
  layers. The corona, photons, sparks, and pulses follow this rule.
- Cinematic active motion runs at nominal and fair thermal states. Low Power
  Mode or serious/critical thermal pressure automatically removes the expensive
  path morphs, photon/corona motion, and gyroscope animation while preserving
  the state, labels, core, and basic rings. Foundation notifications trigger
  this transition; no temperature polling loop is added.
- Keep paths simple and layer bounds integral where practical.
- Do not add dynamic shadows without an explicit `shadowPath`.
- Respect `accessibilityDisplayShouldReduceMotion`; the static state must remain
  understandable without animation.
- Respect `accessibilityDisplayShouldReduceTransparency`.
- State text must remain present because color alone cannot communicate status.
- The panel remains non-activating and ignores mouse events so it cannot steal
  focus from TradingView, Chrome, or full-screen work.
- The compact standby panel is 112 points; active states are 248 points.
- A delayed dismiss must check `transitionGeneration`. Otherwise an old speech
  completion can collapse a newer listening or reasoning state.

## Settings and lifecycle

`persistentPresenceEnabled` is stored in the app's `UserDefaults` domain and
defaults to true. The menu contains:

- **Keep Jarvis Presence Visible** — ambient compact orb on/off.
- **Preview Jarvis Presence** — cycles real state visuals without running an
  action, loading a language model, or accessing the microphone.

Startup presents standby. Sleep and Siri handoff fully hide it. Wake and Siri
completion restore standby if enabled. Normal voice completion and capture
completion collapse back to standby.

## Build and verification

From the repository root:

```sh
JARVIS_NONINTERACTIVE=1 ./bootstrap.command
env PYTHONPATH=. .venv/bin/python -m unittest discover -s tests
codesign --verify --deep --strict --verbose=2 ~/Jarvis/App/Jarvis.app
```

Render any static state without launching a second app instance:

```sh
~/Jarvis/App/Jarvis.app/Contents/MacOS/Jarvis \
  --render-presence-preview standby
~/Jarvis/App/Jarvis.app/Contents/MacOS/Jarvis \
  --render-presence-preview listening
~/Jarvis/App/Jarvis.app/Contents/MacOS/Jarvis \
  --render-presence-preview thinking
```

Supported preview names are `standby`, `awakening`, `listening`, `thinking`,
`speaking`, `capturing`, and `rejected`.

Trigger the live sequence in the already-running installed app without using
the microphone:

```sh
~/Jarvis/App/Jarvis.app/Contents/MacOS/Jarvis \
  --preview-presence-live
```

After source changes, rebuild, terminate only the `Jarvis` process, and reopen
the installed app. Use **Preview Jarvis Presence** for live animation QA. Check
`pmset -g therm`, idle RSS/CPU, wake-listener recovery, and the full tests before
claiming completion.

## Known manual boundary

PNG previews verify geometry, colors, clipping, and state labels. They do not
prove temporal smoothness. A human must ultimately judge motion character on
the actual display. The implementation deliberately includes a menu preview so
that this final check requires no microphone input and causes no external
action.

## Latest verification snapshot

On 2026-08-04 the second-generation implementation was rebuilt and passed all
186 tests plus strict deep code-signature verification. Every static state and
the live animation were visually sampled. A live Core Graphics window audit
observed the panel at 248 by 248 points throughout the complete preview
sequence, then 112 by 112 points after it settled to standby. The native app
stayed near 39 MB resident; sampled CPU was 0.0-0.9% in standby and 0.6-1.8%
during the full cinematic preview. macOS reported no thermal or performance
warning, and the wake listener resumed after reinstall. These are point-in-time
measurements on the user's Mac and should be re-measured after material
animation changes.
