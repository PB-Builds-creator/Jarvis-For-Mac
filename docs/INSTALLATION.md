# Installation

Jarvis is currently a source build for Apple-silicon Macs. The installer uses ad-hoc local signing, so replacing the installed bundle can require macOS permissions to be granted again.

## 1. Requirements

- macOS 14 or newer on Apple silicon
- Python 3.11+
- Xcode or Command Line Tools with a macOS 26 SDK for every optional helper
- several gigabytes of free disk space for the full model set

## 2. Inspect and verify

```bash
git clone https://github.com/PB-Builds-creator/Jarvis-For-Mac.git
cd Jarvis-For-Mac
python3 -m venv .venv
.venv/bin/python -m pip install --constraint constraints.txt -e .
./scripts/verify.sh
```

## 3. Choose a build

Fast verification build without model downloads:

```bash
JARVIS_ROOT="$(mktemp -d)/Jarvis" \
JARVIS_VERIFICATION_BUILD=1 \
JARVIS_NONINTERACTIVE=1 \
./bootstrap.command
```

Full daily-use installation:

```bash
./bootstrap.command
```

The full command installs to `~/Jarvis`. It does not install a public binary into `/Applications`.

## 4. Configure

The first run creates `~/Jarvis/Data/no_api_config.json`. Compare it with `config.example.json` and set only what you need.

Important values:

- `owner_name`: bounded prompt personalization for local/delegated context;
- `chat_workspace` and `work_workspace`: local task scopes for the desktop adapter;
- `approved_chrome_profile_email`: optional exact Chrome profile; leave blank to disable pinned-profile actions;
- `retain_voice_recordings`: keep `false` unless explicitly debugging private audio;
- `private_mode`: blocks desktop/cloud handoff;
- local-model and memory headroom limits.

Do not commit `no_api_config.json` or anything under `~/Jarvis/Data`.

## 5. Grant macOS permissions

Open `~/Jarvis/App/Jarvis.app`, then enable only the features you intend to use under **System Settings → Privacy & Security**:

- Microphone and Speech Recognition for voice;
- Accessibility for confirmed UI actions;
- Screen & System Audio Recording for window capture;
- Calendars, Reminders, and Contacts for those native adapters;
- Automation when controlling another application requires Apple Events.

For Screen Recording, permission must match the exact installed app identity. Avoid rebuilding the app after granting permission unless necessary.

## 6. Validate

1. Open **Jarvis Status** and confirm the wake listener and selected microphone.
2. Use **Preview Jarvis Presence**; this requires no microphone or model.
3. Test one harmless request such as the time and date.
4. Test one app launch and review the proposed plan.
5. Test screen capture only after granting its permission.

See [EVALUATION.md](EVALUATION.md) for the full manual protocol and [../TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for common failures.
