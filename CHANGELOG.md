# Changelog

## [4.0.1] — 2026-04-01

### Fixed

- Reset the daily baseline to `0` on the first day of a new billing period.
- Recompute the adaptive daily quota when the billing period or day-opening baseline changed, so a stale same-day value like `Today: 16/8` is not reused.
- Added regression tests for billing-period rollover and adaptive quota cache reuse.

### Changed

- Bumped the extension package version to `4.0.1`.

## [3.0.0] — 2026-03-24

### Added

- **Paid premium tracking:** When you exceed your included quota, the lens displays your real-time spending in dollars (e.g., `┃$4.78┃`).

### Changed

- **No token setup required** — works automatically with your GitHub account.
- Background refresh no longer flashes the status bar indicator.

## [2.0.0] — 2026-03-06

### Changed

Usage data is now significantly more up-to-date, reflecting activity within the current session rather than after a processing delay.

## [1.0.0] — 2026-02-24

Initial release.



