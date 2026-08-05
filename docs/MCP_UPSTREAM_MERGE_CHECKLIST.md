# MCP upstream merge checklist

Status: merge preparation for the local unified candidate. This checklist does
not authorize a push, pull request, merge, or release tag.

## Remote baseline snapshot

Read-only GitHub inspection on 2026-08-05 established:

- `main`: `884b489` (identical to local `v0.1.3`)
- PR #4: `55e3582`, experimental Metal 2D, open against `main`
- PR #5: `e310198`, CPU IOSurface hot path, open against `main`
- PR #6: `f105183`, CPU saturation follow-up, open against PR #5
- no MCP pull request exists

The MCP candidate therefore has no upstream-base drift at this snapshot.
Recheck the remote heads immediately before opening or merging any PR.

## Required implementation order

Review the existing commits in this order; do not reorder or partially combine
the semantic-owner transitions:

1. A1 scheduler and caller ownership
   - `743f5f5`, `77ea950`, `e91018f`, `0f2d610`, `24bf532`, `7acf94c`
2. A3 bounded capture and release compiler boundary
   - `c2596fc`, `687d6d8`
3. C1 upstream input authority and API compatibility
   - `3025913`, `56add09`, `8fba1b2`, `037d64d`
4. G0a content-free wire metrics
   - `5cb3093`
5. A2 private clipboard offer path
   - `f6b4884`, `4278015`, `b92b78c`, `11025c4`, `563dd4e`, `5e3191b`,
     `d81df5a`

These 20 implementation commits are already one linear chain. Evidence-only
commits may follow them, but they are not implementation dependencies.

## Isolation from performance PRs

A path-set comparison at the fixed heads above found:

- PR #4 overlaps the MCP candidate in exactly three paths:
  `Sources/SpiceProbe/main.swift`, `Sources/SwiftSpice/SpiceSession.swift`, and
  `docs/STATUS.md`.
- PR #5 and PR #6 have no path overlap with the MCP candidate.

PR #4 remains an experimental renderer change and must not be pulled into the
MCP release candidate. Prefer merging the MCP chain first. If PR #4 lands first,
rebase the entire MCP chain onto the new `main`, review all three overlapping
paths, and rerun every final gate below. A conflict-free Git result is not a
substitute for semantic review of session diagnostics or probe command routing.

## Phase review points

### A1

- one bounded typed Agent scheduler owns physical fragments and token reserve
- clipboard, monitor, and file callers have exactly one semantic wire owner
- cancellation before first fragment removes work; cancellation after start
  detaches the caller without duplicating the logical message
- migration, rollback, reconnect, and zero-token invalidation cannot resurrect
  stale work

### A3

- capture is bounded by pixels and encoded bytes
- crop coordinates use top-left frame space
- IOSurface capture does not materialize the full CPU frame first
- cursor inclusion, cancellation, stale revision, and source lifetime remain
  explicit
- the Swift 6.3 release compiler workaround stays limited to the reviewed
  non-inlining ownership boundaries

### C1 upstream

- public symbolic keys remain the sole AppKit/application mapping authority
- legacy `SpiceDesktopView` source compatibility is preserved
- human activity and focus cleanup are distinct; cleanup releases buttons then
  keys and does not create takeover activity
- the real AppKit key-window focus gate passes
- API digester reports no removed or renamed v0.1.3 declarations

### G0a telemetry

- metrics contain only completed message and payload-byte counts
- no payload bytes, names, paths, hashes, or file contents enter logs
- zero-token stop and teardown remain observable without sending a file message

### A2

- signed `MAX_CLIPBOARD` values preserve `-1`, zero, finite peer limits, cap
  withdrawal, and reconnect semantics
- general pasteboard and manual offers are independent authorities
- serial and no-release capabilities are advertised only with complete support
- offer ID and lease generation remain host-only bookkeeping
- GRAB and DATA results follow physical writer terminals
- recent result recovery and event buffering are both bounded to 32 entries
- no API reads/writes the general pasteboard in manual-only mode

## Final merge-commit gates

Run these against the exact tree proposed for `main`, after any rebase or
conflict resolution:

```sh
swift test --disable-sandbox -Xswiftc -warnings-as-errors --no-parallel
scripts/check-api-compatibility.sh v0.1.3
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors
```

The full test must run where local TCP listeners, Security key creation,
IOSurface, Metal, and VideoToolbox are available. Expected evidence for the
currently fixed tree is 441 tests / 71 suites, all three package products built,
and an API graph with exactly 12 reviewed additive enum cases.

Then consume that exact checkout from the Maspice integration branch and rerun:

- VVConfig checks
- SpiceSessionLogic tests
- Maspice root warnings-as-errors tests, including real local UDS tests
- release app/helper assembly and native dependency closure audit
- strict nested signing verification
- `make g0a-built-app-check`

## Tag and app-pin boundary

Do not create the compatible exact tag until:

- the complete implementation chain is on upstream `main`
- final-main API, full-test, and release-product gates pass
- release notes identify the 12 additive enum cases as an exhaustive-switch
  source consideration
- required live VDAgent interoperability has passed for the phase being enabled

After the tag exists, replace Maspice's integration-only path dependency with
that exact version, resolve a normal single-checkout `Package.resolved`, and run
`make doctor`, `make test`, and `make build` again. A local path dependency,
ad-hoc app signature, or successful Git merge alone cannot close the release
gate.
