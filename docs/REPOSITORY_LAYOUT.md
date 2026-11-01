# Repository layout

SwiftSpice follows Swift Package Manager conventions at the root. Supporting
tools and local validation fixtures have one directory per responsibility.

## Top-level directories

| Directory | Contents |
| --- | --- |
| `Sources/` | SwiftPM library and executable source targets |
| `Tests/` | SwiftPM test targets and checked-in fixtures |
| `Plugins/` | SwiftPM command and build-tool plugins |
| `ProtocolSchema/` | Pinned source schema for generated SPICE declarations |
| `Scripts/` | Repository-wide build, packaging, generation, and verification commands |
| `Artifacts/` | Reproducible, checked-in native XCFramework dependencies |
| `Benchmarks/` | Opt-in local performance workloads and native codec checks |
| `docs/` | Current architecture, status, protocol notes, and repository guidance |

The root contains the SwiftPM manifest, project entry-point README, changelog,
version file, license, and third-party notices. Generated build output belongs
in `.build/` and must remain ignored.

## Placement rules

- Put a reusable library or executable module in `Sources/<TargetName>/` and
  its tests in `Tests/<TargetName>Tests/`.
- `Sources/CSpiceQUIC` contains the standalone C declarations and bounded bridge
  for the spice-gtk QUIC binary target. Its upstream C sources are fetched and
  checksum-verified by `Scripts/build-quic-native.sh`; native C ABI tests live
  in `Tests/CSpiceQUICTests`. It is not a SwiftPM C target or a system-library fallback.
- Put SwiftPM build logic in `Plugins/`. A helper used only by one plugin stays
  beside that plugin.
- Put commands used across the repository in `Scripts/`. Use lowercase
  hyphenated filenames, such as `build-lib.sh`.
- Put local performance workloads in `Benchmarks/` and keep their dependencies
  opt-in. Keep small independent correctness fixtures beside their tests.
- Use `spice-probe` against an explicitly configured live endpoint; do not add
  machine-specific VM provisioning or remote campaign orchestration to the package.
- Put stable project documentation in `docs/` and use descriptive filenames.
  Remove superseded plans and stale stage logs instead of carrying their task
  IDs and acceptance checklists into current guidance. Keep status tied to
  implemented behavior and dated validation evidence.
- The root `README.md` is the project entry point. A self-contained benchmark
  fixture may keep a local README beside its reproduction scripts and evidence.
- Do not commit credentials, live run logs, downloaded images, or build output.
