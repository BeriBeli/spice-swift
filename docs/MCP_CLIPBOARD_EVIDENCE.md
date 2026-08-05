# MCP private clipboard offer evidence

Status: local upstream candidate on `codex/mcp-c1-key-map`; not merged, tagged,
released, or integrated into the app-side MCP action service.

Candidate commits:

- `f6b4884` — extended clipboard wire codec
- `4278015` — signed peer/local clipboard limits
- `b92b78c` — source arbitration state machine
- `11025c4` — private offer manager flow
- `563dd4e` — default local receive-limit negotiation
- `5e3191b` — peer limit enforcement for both clipboard authorities

## Contract implemented

- The wire codec uses the official message/capability indices: message 14 for
  `MAX_CLIPBOARD`, and capabilities 10, 16, and 17 for max size,
  no-release-on-regrab, and GRAB serial.
- `MAX_CLIPBOARD` is signed little-endian `Int32`: `-1` is unlimited, zero is a
  real zero-byte limit, and values below `-1` are rejected. A missing value,
  reconnect, and capability withdrawal clear the peer limit. A finite peer
  value constrains both general pasteboard offers and manual offers; `-1` keeps
  each authority's local policy (the general receive bound and the 16,000-byte
  manual-offer bound). The advertised local value remains the actual local
  receive bound (`16 MiB - 4` by default), not 16,000.
- General pasteboard synchronization and in-memory manual offers are independent
  authorities. Manual-only mode does not read or write the general pasteboard,
  and an incoming guest GRAB can arbitrate ownership without causing a guest
  DATA request.
- Manual offers carry host-only ID and lease-generation bookkeeping. An
  unchanged pasteboard `changeCount` cannot overwrite them; a real pasteboard
  change, peer takeover, lease revoke, cancellation, or disconnect resolves the
  old offer without attributing a later REQUEST to that old ID.
- `requested` is an intermediate observation. Exactly one of `dataSent`,
  `superseded`, or `revoked` is terminal for an offer. `dataSent` is emitted only
  after the DATA logical message reaches the scheduler's physical write
  terminal.
- `offerClipboardText` returns only after the GRAB logical message reaches its
  physical write terminal. Cancellation and zero-token shutdown finish the
  waiter and revoke the matching lease rather than leaving an orphaned task.
- Serial comparison is modulo 32 bits. Equal/stale peer GRABs are dropped;
  `0xffff_fffe -> 1` is accepted as newer. Peer no-release support selects direct
  regrab; peers without it retain the compatibility `RELEASE -> GRAB` sequence.
- Capability 10 is advertised whenever clipboard negotiation is enabled.
  Capabilities 16/17 are advertised only while the explicit manual-offer mode is
  enabled. Both clipboard authorities disabled advertise no clipboard support.

## Local evidence

Warnings-as-errors focused wire/state run:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/mcp-module-cache-a2 \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/mcp-module-cache-a2 \
swift test --disable-sandbox -Xswiftc -warnings-as-errors \
  --filter 'Clipboard(StateMachine|Protocol)Tests'
```

Result on 2026-08-05: 32 tests in 2 suites passed.

Warnings-as-errors state plus real scheduler/session run:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/mcp-module-cache-a2 \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/mcp-module-cache-a2 \
swift test --disable-sandbox -Xswiftc -warnings-as-errors \
  --filter '(ClipboardStateMachineTests|SpiceSessionTests)'
```

Result on 2026-08-05: 82 tests in 2 suites passed. The session tests block GRAB
at the physical writer and prove that the public offer call does not return
early; they also cover REQUEST/DATA terminal reporting, Task cancellation, and
zero-token manager stop. The state tests additionally prove that a finite peer
limit constrains general pasteboard offers and that `-1` restores local policy.

Source/ABI compatibility gate:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/mcp-module-cache-a2-api \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/mcp-module-cache-a2-api \
scripts/check-api-compatibility.sh v0.1.3
```

Result: passed with baseline API 1,233,160 bytes, current API 1,671,194 bytes,
and 12 exactly reviewed additive enum cases. The one new allowlisted case is the
package-internal `ClipboardStateMachine.Action.manualOffer`; the existing public
`SpiceClipboardEvent` was not extended.

Release build:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/mcp-module-cache-a2-release \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/mcp-module-cache-a2-release \
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors
```

Result: the `SwiftSpice`, `spice-probe`, and `spice-viewer` products built.

## Evidence still missing

- No Linux or Windows VDAgent live peer has yet exercised max-size, serial,
  no-release, regrab, disconnect, or Unicode request/data interoperability.
- The candidate has no upstream merge, compatible exact tag, or app dependency
  update.
- Maspice does not yet call the private offer API, enqueue a paste chord after
  GRAB completion, or expose the C2 MCP schema.
- A serialized full-project run terminated with 436 tests in 71 suites but was
  not green: 28 issues were in existing Metal/IOSurface/global-renderer tests,
  including unavailable `IOSurfaceCreate`/Metal device paths. The clipboard
  suite passed in that run, but this is not accepted as a full regression gate.

Therefore this evidence supports an A2 local functional candidate only. It does
not satisfy the live-peer, exact-release, app-integration, or C2 release gates.
