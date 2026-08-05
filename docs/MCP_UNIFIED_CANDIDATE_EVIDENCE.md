# MCP unified upstream candidate evidence

Status: local unified candidate at `9119ead` on `codex/mcp-c1-key-map`;
not merged, tagged, released, or live-peer validated.

## Fixed topology

The candidate is one linear successor of `v0.1.3` (`884b489`), not a set of
unmerged local branches. Its 20 implementation commits are ordered as follows:

- A1 scheduler and semantic ownership: `743f5f5` through `7acf94c` (6 commits)
- A3 bounded capture and release compiler fix: `c2596fc`, `687d6d8`
- C1 upstream key/input/API compatibility: `3025913`, `56add09`, `8fba1b2`,
  `037d64d`
- G0a content-free file-transfer wire metrics: `5cb3093`
- A2 private clipboard offer path: `f6b4884` through `d81df5a` (7 commits)

Three later commits only maintain candidate evidence. The full branch is 23
commits ahead of `v0.1.3`.

## Package surface

`Package.swift` builds the `SwiftSpice` library and the `spice-probe` and
`spice-viewer` executables. The candidate preserves the v0.1.3 API graph and
adds only the explicitly reviewed surface needed by the phases above.

## Upstream validation

The full test command was run outside the Codex capability sandbox because the
suite intentionally exercises local TCP listeners, Security key creation,
IOSurface, Metal, and VideoToolbox:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/mcp-module-cache-unified \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/mcp-module-cache-unified \
swift test --disable-sandbox -Xswiftc -warnings-as-errors \
  --no-parallel --quiet
```

Result on 2026-08-05: 441 tests in 71 suites passed with zero failures. A run
inside the Codex capability sandbox produced 28 environment issues; the same
fixed source and warnings-as-errors build passed when the required system
capabilities were available. The passing system-capability run, rather than the
sandbox run, is the regression result.

API compatibility:

```sh
scripts/check-api-compatibility.sh v0.1.3
```

Result: passed. The baseline API graph is 1,233,160 bytes, the candidate graph
is 1,672,529 bytes, and all 12 additive enum cases exactly match the reviewed
allowlist. No v0.1.3 declaration is removed or renamed.

Release build:

```sh
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors
```

Result: the `SwiftSpice`, `spice-probe`, and `spice-viewer` products built.

## Maspice integration validation

The integration-only `codex/mcp-phase-b-capture` app branch consumed this exact
checkout through its explicit local path dependency. On 2026-08-05:

- VVConfig passed 28 checks and SpiceSessionLogic passed 4 tests.
- The Maspice root package passed 8 XCTest plus 84 Swift Testing tests in 14
  suites under warnings-as-errors. The six UDS tests require execution outside
  the Codex capability sandbox and passed there.
- The release app and arm64 helper built against this checkout; native-library
  closure audit, inner-first ad-hoc signing, and strict code-sign verification
  passed.
- `make g0a-built-app-check` passed its non-interactive artifact checks.

This is integration evidence only. The app still uses an integration-only path
dependency and ad-hoc identity; it is not evidence of an exact release pin,
Developer ID production identity, notarization, clean-machine operation, or a
live SPICE peer.

## Remaining release evidence

- Upstream review/merge and a compatible exact tag containing the complete
  linear candidate.
- Linux and Windows VDAgent interoperability for scheduler ownership,
  migration, clipboard limits/serial/regrab, Unicode request/data, and
  disconnect behavior.
- Real SPICE framebuffer plus real Codex client validation of bounded capture,
  coordinates, native authorization, and focus cleanup.
- G0a controlled ordinary-file drag/drop and live Agent file-channel zero-send.
- G2 Developer ID, provisioning, production Keychain handshake, notarization,
  stapling, update, Gatekeeper, and clean-machine evidence.

Until those items pass, this document supports a unified local candidate, not a
release-ready claim.

The fixed review order, performance-PR overlap audit, final-main gates, and
exact-tag/app-pin boundary are recorded in
[`MCP_UPSTREAM_MERGE_CHECKLIST.md`](MCP_UPSTREAM_MERGE_CHECKLIST.md).
