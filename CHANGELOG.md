# Changelog

All notable changes to SwiftSpice are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Added build-environment diagnostics and reusable Mach-O dependency auditing.
- Added dedicated library building, viewer debug-run, version-check, release,
  and Makefile task-runner commands.
- Added version, changelog, and release-tag consistency gates.

### Fixed

- Made an asynchronous transport-close assertion evaluate reliably with the
  Swift 6.4 Testing runtime.

## [0.1.8] — 2026-08-20

### Fixed

- Packaged native static dependencies as named frameworks so Swift Build no longer collides on shared module-map and header output paths.

## [0.1.7] — 2026-08-20

### Fixed

- Fixed pointer capture and frame presentation behavior.

## [0.1.6] — 2026-08-08

### Added

- Added content-free clipboard failure diagnostics.

## [0.1.5] — 2026-08-08

### Added

- Exposed Agent wire diagnostics.

## [0.1.4] — 2026-08-08

### Added

- Exposed session diagnostics snapshots.

## [0.1.3] — 2026-08-02

### Fixed

- Fixed SPICE client/server mouse-mode negotiation.

## [0.1.2] — 2026-08-01

### Fixed

- Fixed cursor caching, duplicate cursor presentation, and Retina scaling edges.

## [0.1.1] — 2026-08-01

### Fixed

- Fixed validation of legacy SPICE TLS certificates.

## [0.1.0] — 2026-08-01

### Added

- Published the initial native Swift SPICE client library, viewer, probe, protocol codecs, and checked-in native dependencies.

[Unreleased]: https://github.com/BeriBeli/spice-swift/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/BeriBeli/spice-swift/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/BeriBeli/spice-swift/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/BeriBeli/spice-swift/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/BeriBeli/spice-swift/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/BeriBeli/spice-swift/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/BeriBeli/spice-swift/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/BeriBeli/spice-swift/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/BeriBeli/spice-swift/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/BeriBeli/spice-swift/releases/tag/v0.1.0
