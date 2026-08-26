# SwiftSpice algorithm improvement plan

> 中文说明：本文是后续算法整改任务的执行清单。后续任务应引用稳定的
> `AIP-*` 编号，并在完成验收后更新状态与证据。

| Field | Value |
| --- | --- |
| Status | Active |
| Plan version | 1.0 |
| Swift baseline | `v0.2.7` / `2c577d7` |
| Reference client | spice-gtk/spice-common 0.42 |
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
| AIP-12 | pending | Move the image cache to Session scope with reservations and asynchronous resolves | AIP-11 | Cross-Display cache, lossless replacement, invalidation, cancellation, and capacity tests pass |
| AIP-20 | pending | Introduce a bounded canonical `PixelRegion` | AIP-12 | Random-mask differential tests and pathological 4,096-clip inputs pass |
| AIP-21 | pending | Apply each wire draw command as one Surface transaction and revision | AIP-20 | Failure is atomic and `mutationTransactions == 1` |
| AIP-22 | pending | Replace staged COPY_BITS with direction-aware O(1)-space copying and add bulk/fill kernels | AIP-21 | Eight-direction differential tests pass and `temporaryCopyBytes == 0` |
| AIP-23 | pending | Remove IOSurface/Data backing ping-pong and resolve damage once per publication | AIP-21 | Full raw followed by a 1x1 CPU mutation records zero CPU materialization bytes |
| AIP-30 | pending | Replace framer compaction and payload materialization with segments, `OwnedBytes`, `WireSlice`, and production Span parsing | AIP-23 | A contiguous body has zero copies and a fragmented body is coalesced at most once |
| AIP-31 | pending | Decode LZ into one backing and optimize references and palette expansion | AIP-30 | spice-common fixtures remain bit-exact with one decoded-output allocation |
| AIP-32 | pending | Split GLZ coordination from CPU workers and use a bounded codec `TaskExecutor` | AIP-31 | Independent images overlap execution while dictionary order, cancellation, and limits remain deterministic |
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
  a Display channel. Cache mutations use a noncopyable reservation with an
  explicit consuming commit or abort; commit cannot fail after Surface success.
- Cache resolves support at most 64 pending waiters, cancellation, Session
  close, lossy/lossless requirements, and a retained-byte budget no larger than
  the cache byte budget.

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
| AIP-11 | 2026-08-26 | PR #21 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; `ProcessedSerialBarrierTests` 14/14; combined serial-barrier tests 17/17; AIP-10 batch regression 12/12; `SpiceSessionTests` 59/59; `DisplayChannelTests` 50/50; `git diff --check` | Effective full and implicit-mini serials advance after the physical batch handler and ACK succeed. Handler/transport failure, cancellation, and close terminate only dependent unsatisfied waiters. Superseded receive tasks cannot poison a replacement connection or its shared barrier; an already-started Agent byte stream remains on its captured connection. `migrationRequested` remains recoverable. |

## Decision log

| Date | IDs | Decision | Reason |
| --- | --- | --- | --- |
| 2026-08-26 | All | Use a dedicated plan under `docs/`; keep `ROADMAP.md` concise | Makes task state and acceptance evidence durable without turning the project roadmap into an implementation diary |
| 2026-08-26 | All | Treat the 2026-08-01 Rocky result as historical, not a `v0.2.7` baseline | The retained measurement predates substantial display, IOSurface, publication, and NEON changes |
| 2026-08-26 | AIP-00, AIP-10—AIP-12 | Permit protocol-correctness work while the external live baseline remains pending; prohibit performance claims until AIP-00 is done | Correctness fixtures are deterministic and do not depend on a live performance endpoint |
| 2026-08-26 | AIP-10, AIP-11 | Keep receive-time serial-barrier behavior unchanged while landing physical-message batches | The batch boundary and ACK ownership are prerequisites for processed-time completion; moving the barrier is separately gated by AIP-11 failure, cancellation, and close semantics |
