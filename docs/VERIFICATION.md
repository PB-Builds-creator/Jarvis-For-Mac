# Verification record

## Public snapshot — 2026-08-06

Environment:

- Mac: Apple M4 Pro, 24 GB unified memory
- OS: macOS 26.6 (25G72)
- Xcode: 26.6 (17F113)
- Swift: 6.3.3
- Python used for local verification: 3.14.6

Completed evidence:

| Check | Result |
|---|---|
| Python and native-source contract suite | 186/186 passed |
| `ResourceWarning` policy | passed with warnings promoted to errors |
| Built-in public privacy/token scan | passed |
| Staged-source private path/account scan | passed |
| Markdown local-link validation | passed |
| GitHub workflow and issue-template YAML parsing | passed |
| Shell syntax, JSON, plist, and entitlement validation | passed |
| Swift frontend parsing | passed |
| Python wheel build | passed; `jarvis_macos-1.0.0-py3-none-any.whl` |
| Clean local clone | passed |
| All native Swift helpers compiled from the clean clone | passed |
| App Intents metadata extraction | passed |
| Ad-hoc Hardened Runtime bundle signing and strict deep verification | passed |
| Static listening/reasoning presence render | passed |
| macOS thermal warning state at verification time | none recorded |

The clean-clone build used a temporary `JARVIS_ROOT` and `JARVIS_VERIFICATION_BUILD=1`; it did not replace or launch the private daily-use installation and did not download model weights.

## Explicitly not claimed by this record

This public packaging pass did not re-run live wake-word accuracy, non-owner voice rejection, real microphone endpointing, Siri handoff, actual ScreenCaptureKit capture, live TradingView restoration, or whole-process-tree CPU/RSS sampling. Those behaviors depend on macOS permissions, hardware, accounts, and application state. Follow [EVALUATION.md](EVALUATION.md) before making a dated release claim about them.

GitHub-hosted CI for Python 3.12 and 3.13 will become evidence only after the repository is published and both matrix jobs complete successfully.
