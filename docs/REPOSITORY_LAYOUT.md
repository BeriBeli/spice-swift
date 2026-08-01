# Repository layout

SwiftSpice follows Swift Package Manager conventions at the root. Supporting
tools and external validation fixtures have one directory per responsibility.

## Top-level directories

| Directory | Contents |
| --- | --- |
| `Sources/` | SwiftPM library and executable source targets |
| `Tests/` | SwiftPM test targets and checked-in fixtures |
| `Plugins/` | SwiftPM command and build-tool plugins |
| `ProtocolSchema/` | Pinned source schema for generated SPICE declarations |
| `Scripts/` | Repository-wide build, packaging, generation, and verification commands |
| `Artifacts/` | Reproducible, checked-in native XCFramework dependencies |
| `Integration/` | Live external-system fixtures, grouped by host environment |
| `Benchmarks/` | Performance collectors, orchestration, analysis, and retained summaries |
| `docs/` | Architecture, status, roadmap, and repository guidance |

The root contains the SwiftPM manifest, project entry-point README, license, and
third-party notices. Generated build output belongs in `.build/` or `dist/` and
must remain ignored.

## Placement rules

- Put a reusable library or executable module in `Sources/<TargetName>/` and
  its tests in `Tests/<TargetName>Tests/`.
- Put SwiftPM build logic in `Plugins/`. A helper used only by one plugin stays
  beside that plugin.
- Put commands used across the repository in `Scripts/`. Use lowercase
  hyphenated filenames, such as `build-and-run.sh`.
- Put host-specific live environments in `Integration/<Environment>/`. Scripts
  used only by one fixture stay inside that fixture.
- Put measurement tools and result summaries in `Benchmarks/`. Do not mix
  benchmark orchestration with correctness gates.
- Put stable project documentation in `docs/` and use descriptive filenames.
  The root `README.md` is the only file named `README.md`.
- Do not commit credentials, live run logs, downloaded images, or generated app
  bundles.

## Integration layout

`Integration/AppleContainer/` contains the local nested-virtualization gate.
`Integration/RemoteRocky/` contains remote x86_64 fixtures for performance,
video, audio, and WebDAV. Each fixture owns its guest, remote lifecycle scripts,
ports, and ticket handling.

Operational guides stay next to the fixture they describe, but their filenames
identify the subject. The documentation index links all of them.
