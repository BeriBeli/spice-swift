# SwiftSpice algorithm improvement plan

> 中文说明：本文是后续算法整改任务的执行清单。后续任务应引用稳定的
> `AIP-*` 编号，并在完成验收后更新状态与证据。

| Field | Value |
| --- | --- |
| Status | Active |
| Plan version | 1.1 |
| Swift baseline | `v0.2.7` / `2c577d7` |
| Reference client | spice-gtk `88ad5f1` (v0.43/master) / spice-common `71e4570` (master), reverified 2026-08-27 |
| Created | 2026-08-26 |

This plan is the source of truth for active algorithm work. [STATUS.md](STATUS.md)
records completed evidence, while [ROADMAP.md](ROADMAP.md) remains the compact
project-level summary. The retained 2026-08-01 Rocky benchmark predates the
current release and is historical evidence only; it must not be quoted as the
performance of `v0.2.7`.

## Goals and invariants

The work is ordered as protocol correctness, rendering transactions, ownership
and copy reduction, then measured concurrency improvements. Preserve these
invariants throughout:

1. Do not change the public `SwiftSpice` API.
2. Do not add pixman or another rendering runtime dependency.
3. A failed wire command must not partially publish Surface or cache state.
4. `Span` is synchronous and non-escaping. Only a Sendable owner plus a range
   may cross an actor boundary or suspension point.
5. Preserve spice-common PLT4 modulo semantics and the current MJPEG
   one-in-flight/one-latest policy.
6. Do not claim a performance change without a fresh, versioned measurement.

## Status model

Use exactly one of these values in the work table:

- `pending`: dependencies or implementation have not completed.
- `in-progress`: the item is the primary scope of an active task.
- `blocked`: progress requires a recorded external action or decision.
- `done`: every completion gate passed and evidence is linked below.
- `deferred`: explicitly removed from the active release scope in the decision
  log.

## Work items

| ID | Status | Work item | Depends on | Completion gate |
| --- | --- | --- | --- | --- |
| AIP-00 | pending | Establish fresh `v0.2.7` metrics and a Release `spice-bench` JSON harness | — | Microbench and live artifacts identify commit, toolchain, hardware, thermal state, workload, and date |
| AIP-10 | done | Add an owned physical-message model and strict full-header submessage lists | — | List-only and main-plus-list ordering, bounds, ACK, fragmentation, and mutation tests pass |
| AIP-11 | done | Advance the serial barrier after processing and propagate channel failure | AIP-10 | Waiters remain blocked through handler work and terminate on success, failure, cancellation, or close |
| AIP-12 | done | Move the image cache to Session scope with ordered mutations and asynchronous resolves | AIP-11 | Cross-Display cache, lossless replacement, invalidation, FIFO, cancellation, and capacity tests pass |
| AIP-20 | done | Introduce a bounded canonical `PixelRegion` | AIP-12 | Random-mask differential tests and pathological 4,096-clip inputs pass |
| AIP-21 | done | Apply each wire draw command as one Surface transaction and revision | AIP-20 | Failure is atomic and `mutationTransactions == 1` |
| AIP-22 | done | Replace staged COPY_BITS with direction-aware O(1)-space copying and add bulk/fill kernels | AIP-21 | Eight-direction differential tests pass and `temporaryCopyBytes == 0` |
| AIP-23 | done | Remove IOSurface/Data backing ping-pong and resolve damage once per publication | AIP-21 | Full raw followed by a 1x1 CPU mutation records zero CPU materialization bytes |
| AIP-30 | done | Replace framer compaction and payload materialization with segments, `OwnedBytes`, `WireSlice`, and production Span parsing | AIP-23 | A contiguous body has zero copies and a fragmented body is coalesced at most once |
| AIP-31 | done | Decode LZ into one backing and optimize references and palette expansion | AIP-30 | spice-common fixtures remain bit-exact with one decoded-output allocation |
| AIP-32 | in-progress | Split GLZ coordination from CPU workers and use a bounded codec `TaskExecutor` | AIP-31 | Independent images overlap execution while dictionary order, cancellation, and limits remain deterministic |
| AIP-33 | pending | Parse Annex-B once and reduce VideoToolbox sample copies | AIP-30 | Copy counters improve and CoreMedia owner-lifetime tests pass on success, cancellation, and teardown |
| AIP-40 | pending | Connect child channels with bounded concurrency | AIP-32 | Concurrency never exceeds four and failure leaves no connected transport behind |
| AIP-41 | pending | Prepare independent Surface snapshots with bounded concurrency | AIP-32 | A blocked Surface does not prevent another from starting and emit order stays stable |
| AIP-42 | pending | Replace realtime audio queues with preallocated rings | AIP-00 | Realtime callbacks perform no linear queue movement or per-packet allocation |
| AIP-43 | pending | Move blocking WebDAV filesystem work to a bounded executor | AIP-00 | Slow I/O does not block an unrelated client while per-client order is preserved |
| AIP-90 | pending | Run final regression, interoperability, and documentation closure | All applicable items | Full tests and fresh live gates pass and final evidence is recorded in `STATUS.md` |

## Required designs

### Protocol ordering and shared cache

- A physical full-header message owns one immutable body. Logical submessages
  are ranges into that owner, execute in list order, and precede the main
  message. `SPICE_MSG_LIST` has no separately dispatched main message.
- Default to at most 4,096 submessages. Reject checked-arithmetic overflow,
  truncated tables, duplicate or overlapping entries, metadata references, and
  out-of-body payloads before dispatching any logical message.
- ACK is counted once per physical message. Its effective full or implicit-mini
  serial advances only after ordered protocol state and Surface/cache effects
  complete. Asynchronously presented video is complete once it has been
  reliably admitted to its bounded scheduler.
- `DisplayImageCache` is one Session-owned actor. Palette caches remain local to
  a Display channel. Cache mutations register a noncopyable intent before any
  asynchronous source resolution or decode, stage the decoded bitmap afterward,
  and use an explicit consuming commit or abort; commit cannot fail after
  Surface success. Same-ID mutations acquire the active slot through a bounded,
  cancellation-safe FIFO.
- Cache resolves support at most 64 pending waiters, cancellation, Session
  close, lossy/lossless requirements, and a retained-byte budget no larger than
  the cache byte budget. Active and queued mutation counts, mutation-retained
  message bytes, and staged bitmap bytes are likewise bounded. Targeted and
  global invalidation mark every mutation already registered at their
  linearization point without retaining unknown-ID tombstones. When a logical
  submessage suspends, retained-byte accounting uses its complete physical
  batch backing size rather than the smaller logical `Data` slice.

### Rendering transactions

- `PixelRegion` represents ordered y bands with sorted, disjoint x intervals.
  Build `destination ∩ surfaceBounds ∩ union(clips)` with checked half-open
  coordinates, coordinate compression, a y sweep, and coverage counts.
- Preserve allocation-free paths for no clip and a single rectangle. Limit the
  normalized result to 65,536 segments and fail before mutation on overflow.
- Region-level fill, copy, and draw operations acquire a Surface once, validate
  every source and destination, prepare backing once, advance one mutation
  generation/revision, and commit one damage result.
- Same-Surface COPY_BITS traverses bands and rows opposite the move direction
  and uses `memmove` per row. Cross-Surface copy directly traverses rows after
  both materializations succeed. Neither path allocates an area-sized staging
  buffer.
- When IOSurface is canonical and Data is stale, apply a CPU operation directly
  to a synchronized revision candidate instead of performing an IOSurface to
  Data to IOSurface round trip.

### Swift ownership and codec execution

- The framer uses a head-index segment queue. A contiguous message retains its
  input owner and range; a fragmented message is coalesced exactly once.
- Generated and handwritten protocol readers borrow a non-escaping Span.
  Payload fields retain `OwnedBytes`; public events materialize `Data` only at
  their existing boundary.
- LZ writes directly into `Data(count:)`, uses overlap-aware doubling copies,
  and expands palette bytes through a precomputed BGRA lookup table.
- The Session codec executor has width two. Stateful MJPEG decoding retains its
  existing per-stream serial executor; GLZ keeps dictionary coordination in an
  actor and moves independent CPU work to bounded workers.
- Advanced video scans Annex-B into NAL ranges in one pass and constructs AVCC
  in one allocation. A no-copy `CMBlockBuffer` path is allowed only after its
  retained-owner callback is covered by lifetime tests.

## Measurement and acceptance

`spice-bench` must run in Release mode, warm up inputs, retain a checksum to
prevent dead-code elimination, and emit JSON. It covers wire split patterns,
regions, COPY_BITS, LZ/GLZ, IOSurface backing transitions, and advanced-video
sample construction.

For a targeted microbenchmark, the change must improve the target and the 95%
confidence-interval upper bound for unrelated cases must not regress beyond
1.05. Required exact counters include:

- `bodyCopyBytes == 0` for contiguous framing.
- At most one body-sized copy for fragmented framing.
- `mutationTransactions == 1` for a non-empty clipped command.
- `temporaryCopyBytes == 0` for COPY_BITS.
- One bulk call and zero row calls for a tightly packed full IOSurface copy.
- `cpuMaterializationBytes == 0` for full-raw then 1x1 mutation on a supported
  revisioned IOSurface path.

The final live decision uses ten paired 30-second runs and the existing gates:
fps lower bound 0.95; ready-frame, p95, and CPU-per-frame upper bound 1.10; RSS
upper bound 1.15; and zero stale publications, pool exhaustion, or GPU errors.
Real-window 1080p/4K at 60/120 Hz and audio-device behavior remain separate
acceptance gates.

## Execution protocol

1. A future task names one primary ID, for example `Execute AIP-10`.
2. Verify every dependency is `done`, then change the item to `in-progress` in
   the same branch as the work.
3. Keep one primary item per branch unless the decision log explicitly records
   why two items are inseparable.
4. Mark an item `done` only after its completion gate passes. Add an evidence
   row with the date, commit or PR, tests, benchmark artifact, and material
   deviations.
5. If an assumption changes, update the decision log before changing the
   implementation. Never silently weaken a limit or acceptance gate.

## Evidence log

| ID | Date | Commit/PR | Evidence | Notes |
| --- | --- | --- | --- | --- |
| AIP-10 | 2026-08-26 | PR #20 / `f68f6c6` | Apple Silicon SwiftPM CI; `swift build -Xswiftc -warnings-as-errors`; `InboundMessageBatchTests` 9/9 with 14 malformed-list arguments; `ChannelConnectionBatchTests` 3/3; `git diff --check` | Full-header batches share one owned body, dispatch submessages before the main prefix, and count ACK once per physical message. PR CI passed. Live-peer coverage remains for AIP-90. |
| AIP-11 | 2026-08-26 | PR #21 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; `ProcessedSerialBarrierTests` 16/16; combined serial-barrier tests 19/19; `ChannelMigrationTests` 5/5; AIP-10 batch regression 12/12; `SpiceSessionTests` 61/61; `DisplayChannelTests` 50/50; `git diff --check` | Effective full and implicit-mini serials advance after the physical batch handler and ACK succeed. A SET_ACK main or submessage excludes its complete physical batch from the new ACK window. A MIGRATE message may emit its triggered protocol ACK after entering migration state without opening ordinary client sends. Handler/transport failure, cancellation, and close terminate only dependent unsatisfied waiters, and a terminal connection rejects later client sends. Superseded receive tasks cannot poison a replacement connection or its shared barrier; an already-started Agent byte stream drains on its captured retiring connection before that transport closes, without delaying later target sends. Disconnect cancels that retirement wait, closes both retained source and target state, and cannot publish a late migration completion. `migrationRequested` remains recoverable. |
| AIP-12 | 2026-08-27 | PR #22 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; `DisplayImageCacheTests` 17/17; `DisplayChannelTests` 65/65 (one test executes 4 release cases); `SpiceSessionTests` 62/62; combined focused gate 144/144; message-framer/inbound-batch 12/12; connection-batch 3/3; 1,000-iteration immediate-promotion stress; `git diff --check` | One Session-owned actor coordinates every Display image reference. Each noncopyable mutation begins before asynchronous decode, stages its bitmap afterward, and uses consuming commit/abort so cache publication remains behind successful Surface work. Same-ID mutations run through a bounded FIFO instead of being rejected; cancellation, clear, and close release continuations and budgets exactly once. Cross-Display resolves remain bounded to 64 waiters and one cache-sized retained-byte budget. Active/queued mutation counts and retained/staged bytes have hard limits. A logical submessage accounts the complete physical batch storage retained by its `Data` slice, closing the gap between the wire-size limit and the cache budget. Targeted and global invalidation mark all active and queued work registered at their linearization point, preventing decode-time resurrection without retaining unknown-ID tombstones. AIP-11 barriers order `INVAL_ALL_PIXMAPS`; seamless rebinding retains the source cache, while replacement and teardown close exactly their owned cache. No performance claim is made before AIP-00. |
| AIP-20 | 2026-08-27 | PR #23 | `swift build -Xswiftc -warnings-as-errors`; `PixelRegionTests` 5/5 with 500 fixed-seed differential cases; pathological 4,096-clip and 65,536-segment limits; `DisplayChannelTests` 68/68; `SurfaceStoreTests` 37/37; combined focused gate 110/110; `git diff --check` | Display destinations, stream clips, and stream frames normalize `destination ∩ surfaceBounds ∩ union(clips)` before mutation. Nil and single clips use inline storage; multi-clip input uses coordinate compression, a y sweep, and lazy range-add coverage counts to emit canonical bands. Same-Surface clipped copies traverse bands and intervals opposite the translation direction so canonical sorting cannot overwrite a later segment's source. The implementation follows spice-gtk/spice-common pixman region semantics while adding deterministic Swift input/output limits. One-command Surface transactions and the per-row O(1)-space COPY_BITS kernel remain scoped to AIP-21 and AIP-22. No performance claim is made before AIP-00. |
| AIP-21 | 2026-08-27 | PR #24 | `swift build -Xswiftc -warnings-as-errors`; three parameterized transaction tests / 13 wire cases; `DisplayChannelTests` 71/71; `SurfaceStoreTests` 37/37; `PixelRegionTests` 5/5; combined focused gate 113/113; `git diff --check` | Pre-fix acceptance produced 29 issues: five multi-segment commands advanced two revisions without a transaction count, and three later-invalid source cases partially modified their destination. Region-level fill, COPY_BITS, bitmap DRAW_COPY, and same/cross-Surface DRAW_COPY now validate all segments before one backing preparation and one commit. Non-empty commands increment revision, mutation generation, and `mutationTransactions` exactly once; empty and failed commands leave pixels, descriptors, damage, copy/materialization metrics, and source surfaces unchanged. AIP-20 directional traversal remains intact. Per-row O(1)-space COPY_BITS and bulk kernels remain AIP-22 scope. No performance claim is made before AIP-00. |
| AIP-22 | 2026-08-27 | PR #25 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; six parameterized tests / 33 cases; `SurfaceStoreTests` 43/43; AddressSanitizer `SurfaceStoreTests` 43/43; `DisplayChannelTests` 71/71; `git diff --check` | The pre-fix direction oracle passed 19 single/multi-segment cases, confirming correct pixels but not allocation behavior; the four planned metrics were absent. Same/cross-Surface copies now use bounded unsafe-buffer lifetimes with direct `memmove`/`memcpy`, no area staging, and `temporaryCopyBytes == 0`. Same-Surface overlap is always per-row and bottom-up when moving downward; only non-overlapping contiguous rectangles use one bulk call. An independent post-fix test pass caught and closed the initial overlap/bulk classification gap. Fill uses one arm64 NEON kernel call per canonical segment while preserving ARGB/xRGB alpha rules. AIP-21 validation and one-command transactions remain intact. No throughput claim is made before AIP-00. |
| AIP-23 | 2026-08-27 | PR #26 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; six focused tests / nine parameter cases; `SurfaceStoreTests` 46/46; AddressSanitizer `SurfaceStoreTests` 46/46; `SurfacePublicationDamageTests` 3/3; `DisplayChannelTests` 71/71; `git diff --check` | The pre-fix focused gate produced 24 issues: full-raw followed by fill, same-Surface COPY_BITS, partial bitmap DRAW_COPY, or a held lease materialized the complete Surface on the CPU and uploaded damage again at the next snapshot. Eligible CPU kernels now continue from the IOSurface-canonical revision in place when unleased or through a synchronized immutable candidate while a lease is held. The actor rechecks lifecycle, revision, and canonical identity after synchronization; unsafe pointers remain within synchronous IOSurface-lock closures. Dual-canonical cross-Surface copy stays direct. Pool exhaustion falls back atomically to Data. Internal catch-up damage is reset at the direct commit, publication damage is retained until one matching snapshot consumes it, and the public API is unchanged. No throughput claim is made before AIP-00. |
| AIP-30 | 2026-08-27 | PR #27 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; `MessageFramerTests` 14 declarations / 19 parameter executions; `ByteReaderTests` 8/8; `InboundMessageBatchTests` 10 declarations / 23 executions; `SpiceWireTests` 36 declarations / about 54 executions; `SpiceProtocolTests` 46/46; `ChannelConnectionBatchTests` 3/3; `DisplayChannelTests` 71 declarations / 84 executions; AddressSanitizer wire and channel-batch gates; Release strict build; generated-source and Public API checks; `git diff --check` | Pre-fix, malformed `nextBatch` consumed its 43-byte physical boundary before validation and advanced to the next message. Independent testing then caught a segment-boundary out-of-bounds trap and up to 1,023 logically consumed owners retained behind the head index. Latest-head review caught a further owner-amplification path where tiny reads stayed under the byte budget while creating unbounded segment metadata; the framer now rejects a 4,097th live receive segment before owner allocation with `.tooManySegments`, and consumed/reset slots immediately restore capacity. The bounded segment queue retains a contiguous body as one owner/range with `bodyCopyBytes == 0`, coalesces a fragmented body exactly once, never compacts received bytes, and validates a batch before cursor advancement. A malformed fragmented retry reports its one cached coalesced owner without copying again; that cache is byte-bounded but does not consume receive-segment capacity. Production channels and protocol readers accept `WireSlice`; Swift 6 `Span` remains synchronous and non-escaping, while Data is materialized only at established event or codec boundaries. Full-header retained-byte accounting includes the actual input owner. No throughput claim is made before AIP-00. |
| AIP-31 | 2026-08-27 | PR #28 / `6488491` | `swift test --disable-sandbox --no-parallel -Xswiftc -warnings-as-errors`; focused LZ/GLZ gate 24/24; eight AIP-31 declarations / 27 parameter executions in Debug, Release, and AddressSanitizer; `SpiceCodecsTests` 43/43; full AddressSanitizer suite; Release strict build; generated-source and Public API checks; Apple Silicon SwiftPM CI including coverage; `git diff --check` | The previous RGB path allocated `[UInt8]` and then converted it to `Data`; the palette path additionally retained a packed-byte array and rejected an exact final-output byte limit because it budgeted packed plus BGRA storage. All formats now write one preallocated BGRA `Data`. Color and packed references copy one initialized period and double it; alpha references use one strided overlap-kernel call. Palette decoding uses the same backing prefix for packed bytes, then expands rows backwards through a maximum 8 KiB byte-to-BGRA table, preserving partial row tails, cross-row references, 4-bit modulo, and 8-bit rejection. Immutable per-decode diagnostics report one decoded allocation, zero temporary decoded backings, bounded reference calls, and exact lookup pixels. Malformed attempts remain deterministic and publish no result. Review of the implementation commit reported no major issue. No throughput claim is made before AIP-00. |

## Decision log

| Date | IDs | Decision | Reason |
| --- | --- | --- | --- |
| 2026-08-26 | All | Use a dedicated plan under `docs/`; keep `ROADMAP.md` concise | Makes task state and acceptance evidence durable without turning the project roadmap into an implementation diary |
| 2026-08-26 | All | Treat the 2026-08-01 Rocky result as historical, not a `v0.2.7` baseline | The retained measurement predates substantial display, IOSurface, publication, and NEON changes |
| 2026-08-26 | AIP-00, AIP-10—AIP-12 | Permit protocol-correctness work while the external live baseline remains pending; prohibit performance claims until AIP-00 is done | Correctness fixtures are deterministic and do not depend on a live performance endpoint |
| 2026-08-26 | AIP-10, AIP-11 | Keep receive-time serial-barrier behavior unchanged while landing physical-message batches | The batch boundary and ACK ownership are prerequisites for processed-time completion; moving the barrier is separately gated by AIP-11 failure, cancellation, and close semantics |
| 2026-08-27 | AIP-20 | Match spice-gtk/spice-common pixman region union/intersection semantics, but enforce Swift-side clip and canonical-segment limits | Official spice-gtk `88ad5f1` adds stream clips to `QRegion`; spice-common `71e4570` aliases `QRegion` to `pixman_region32_t`, unions rectangles, and intersects destination, canvas, and clip regions. Explicit bounds keep hostile inputs deterministic in Swift. |
| 2026-08-27 | AIP-21 | Treat a normalized region as one Surface transaction, while retaining per-segment copy kernels until AIP-22 | Official spice-common `71e4570` passes one normalized `dest_region` into each canvas draw/blit call. Swift additionally validates every translated source and destination before preparing or publishing value-semantic Surface state. |
| 2026-08-27 | AIP-22 | Reverify current upstream heads and mirror their direction-aware region/row traversal without adding pixman | Current spice-gtk master `88ad5f1` (v0.43 lineage) still delegates COPY_BITS to the canvas. Current spice-common master `71e4570` orders region rectangles by move quadrant, then copies vertical overlap bottom-up, top-down otherwise, and uses per-row `memmove` for horizontal overlap. Swift keeps AIP-20's canonical traversal, applies the same row-direction rule through bounded unsafe-buffer access, adds explicit temporary/bulk-call diagnostics, and preserves AIP-21's one-command transaction. |
| 2026-08-27 | AIP-23 | Keep an IOSurface-canonical revision canonical across eligible CPU mutations, and consume publication damage only after a matching snapshot succeeds | Current spice-gtk master `88ad5f1` allocates one `surface->data` buffer and passes that same memory into the software canvas, so CPU drawing does not read back from a separate presentation backing. Swift cannot expose a mutable published IOSurface, so it checks out an unleased in-place slot or a synchronized revision candidate, performs synchronous CPU work while locked, then atomically publishes the new immutable revision. Actor operation locks and revision checks surround every suspension; unsafe byte access never crosses `await`. Data materialization remains a fallback, not the normal continuation of an IOSurface-canonical revision. |
| 2026-08-27 | AIP-30 | Represent received wire storage as immutable owners plus checked ranges; retain a single input owner for contiguous messages, coalesce fragmented bodies exactly once, and cap live receive owners at 4,096 | Swift 6.3 `Span` is non-escapable and therefore remains a synchronous parsing view, while a Sendable `OwnedBytes` owner/range may safely cross actors and suspension points. The framer uses a head-index segment queue instead of repeatedly compacting one `Data`; scalar/header parsing borrows spans, payload fields retain slices, and conversion to `Data` stays at existing public or subsystem boundaries. Exact copy counters gate contiguous zero-copy and fragmented single-coalescing behavior. The independent segment cap closes metadata/allocation amplification that a byte budget alone cannot bound. |
| 2026-08-27 | AIP-31 | Decode directly into one preallocated `Data` backing, preserve spice-common's forward overlap semantics with bounded doubling copies, and precompute palette-byte-to-BGRA expansion tables | Current spice-common master `71e4570` accepts a caller-owned output buffer, writes each plane directly into it, and advances both reference and output pointers so overlapping matches reproduce prior output. Its palette specializations expand compressed bytes directly to RGB32. Swift retains the same bit-exact semantics and existing hostile-input checks while using synchronous scoped mutable-buffer access; doubling copies reduce long repeated references from per-pixel work to logarithmic bulk-copy calls, and lookup tables remove per-pixel shifts, modulo, and palette loads without introducing a second decoded-output allocation. |
| 2026-08-27 | AIP-32 | Share one GCD-backed Swift `TaskExecutor` of width two per Session, cap FIFO admission at 64 pending jobs and 256 MiB of retained input, and keep GLZ dependency waits outside worker permits | Current spice-gtk master `88ad5f1` owns one GLZ window per Session, explicitly accepts out-of-order image arrival across display sockets, and separates window coordination from per-surface decoders; its GLZ template also records a TODO to split distance/length parsing from copying. Swift 6 task-executor preference moves blocking codec work off the default cooperative pool instead of merely counting it with an actor semaphore. Swift parses a bounded GLZ program, resolves immutable dictionary snapshots in the actor, then acquires Session admission only for cancellation-aware CPU decode. The actor reserves image IDs, commits out-of-order completions with existing contiguous-tail eviction semantics, and rejects commits from an older clear generation. Stateless JPEG/LZ/QUIC and ZLIB work share the executor; stateful MJPEG keeps its per-stream serial executor and existing width-two limiter. FIFO admission, cancellation removal, retained-byte accounting, and immutable diagnostics make overload deterministic without occupying worker slots while waiting on dictionary order. |
