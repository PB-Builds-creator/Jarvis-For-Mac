# Changelog

All notable public changes will be documented here. The project follows semantic versioning for source releases.

## [Unreleased]

### Added

- Public-safe configuration for owner name, Chrome profile, workspaces, and install root.
- Isolated verification build that skips optional model downloads.
- CI, privacy/secret scanning, architecture, evaluation, installation, and case-study documentation.
- Actual rendered presence-state images for the project page.

### Changed

- Removed private paths, account details, desktop task identifiers, and owner-specific seed data from the public source snapshot.
- Closed local HTTP error responses explicitly to prevent descriptor leaks and `ResourceWarning` noise.
- Fixed clean installations by creating the private helper-binary directory before copying signed helpers.
- Generated App Intents metadata input lists during the build instead of relying on machine-specific generated files.

## [1.0.0] - 2026-08-06

- First portfolio-ready source release of the local-first macOS agent.
