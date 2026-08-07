# Contributing

Contributions are welcome when they preserve the project's local-first and human-in-the-loop contracts.

## Setup

```bash
python3 -m venv .venv
.venv/bin/python -m pip install --constraint constraints.txt -e .
./scripts/verify.sh
```

## Pull requests

Keep changes focused and include:

- the user-visible problem;
- the chosen behavior and alternatives considered;
- tests for the success and failure paths;
- exact verification performed;
- privacy, permission, resource, and compatibility effects;
- screenshots or short recordings for visual/voice changes, with private content removed.

## Non-negotiable contracts

- Model or screen content cannot directly authorize Mac actions.
- Consequential actions remain confirmable and interruptible.
- Financial analysis never executes a trade.
- Private Mode blocks external reasoning handoffs.
- Owner voice does not replace Touch ID.
- Raw voice recordings are deleted by default.
- TradingView scans restore 5m with Interval and Date Range synchronization off.
- Failures are reported precisely; tests do not imply unperformed hardware verification.

## Scope

Good contributions improve safety, evaluation, portability, resource behavior, documentation, testability, or a clearly bounded capability. Please discuss large new model downloads, continuous background inference, expanded permissions, or new external side effects before implementation.
