# Security policy

## Supported versions

Security fixes are applied to the latest source on `main`. The project does not currently distribute a notarized binary or promise security support for copied app bundles.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that could expose local data, bypass confirmation, execute an ungrounded action, cross a permission boundary, or permit another process or browser page to control Jarvis.

Use the repository's **Security → Report a vulnerability** flow after publication. Include the affected revision, macOS version, reproduction steps, impact, and whether the issue requires an already-unlocked local account. Remove voice recordings, screenshots, account identifiers, credentials, and personal memory from the report.

## Security properties

- The dashboard listens only on `127.0.0.1` and requires an ephemeral process token. Host validation, same-origin checks, strict cookies, bounded request bodies, and security headers reduce exposure to untrusted browser pages.
- Python launches in isolated mode with a reduced environment and does not inherit proxy, dynamic-loader, or arbitrary `PYTHONPATH` configuration from the app.
- The local development app uses Hardened Runtime and strict signature verification. Public binary distribution still requires Developer ID signing and notarization.
- Local model downloads are pinned to exact revisions; direct file downloads also use SHA-256 checks where practical.
- Screen and OCR content is treated as untrusted evidence.
- Model output is a proposal. Deterministic native/Python policy validates allowed types, bounded payloads, user-request grounding, risk, and confirmation before execution.
- Voice commands receive a transcript preview. Local actions receive an exact plan preview. Higher-risk side effects use stronger confirmation.
- Financial requests are analysis only. Jarvis cannot place, modify, or close live trades.
- Owner Voice is a probabilistic personalization gate. Touch ID remains required for protected credentials and voice-profile changes.
- Raw enrollment and verification recordings are deleted by default. Numeric speaker profiles and secrets are stored through macOS Keychain.
- Private Mode blocks external reasoning handoff and excludes private memory from outbound context.
- Local file actions are restricted to visible content under the current user's home directory; hidden/system paths and Jarvis's App, Code, Data, and Models are protected.
- macOS remains the authority for Screen Recording, Accessibility, Microphone, Speech, Automation, Calendar, Reminders, and Contacts.

## Threat-model limits

These controls address accidental execution, hostile screen text, malformed model output, untrusted local web pages, common injection paths, other macOS accounts, and unsigned bundle replacement. They do not guarantee secrecy after malware obtains the logged-in user's authority, administrator/root access, kernel control, or physical access to an unlocked Mac.

Speaker verification cannot prove liveness against every replay or synthetic-voice attack. Accessibility permission is powerful by design. FileVault protects data at rest while the Mac is locked or powered off, not while an unlocked account is compromised.
