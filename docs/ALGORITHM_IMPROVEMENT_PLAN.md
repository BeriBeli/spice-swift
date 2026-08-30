# SwiftSpice algorithm improvement plan

> 中文说明：本文是后续算法整改任务的执行清单。后续任务应引用稳定的
> `AIP-*` 编号，并在完成验收后更新状态与证据。

| Field | Value |
| --- | --- |
| Status | Active |
| Plan version | 1.8 |
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
and copy reduction, then measured concurrency improvements. Within measured
work, perceived interaction latency is the highest priority, followed by visual
clarity; CPU and RSS are guardrails rather than primary optimization targets.
Preserve these invariants throughout:

1. Do not change the public `SwiftSpice` API.
2. Do not add pixman or another rendering runtime dependency.
3. A failed wire command must not partially publish Surface or cache state.
4. `Span` is synchronous and non-escaping. Only a Sendable owner plus a range
   may cross an actor boundary or suspension point.
5. Preserve spice-common PLT4 modulo semantics and the current MJPEG
   one-in-flight/one-latest policy.
6. Do not claim a performance change without a fresh, versioned measurement.
7. Keep desktop delivery latest-only and outside per-frame SwiftUI observation;
   an idle view with no new revision must not acquire a drawable or commit Metal
   work.
8. Keep at most two Metal commands in flight. A low-latency path may bypass a
   frame-clock wait only when command admission and drawable acquisition are
   both known not to block.

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
| AIP-00 | in-progress | Establish fresh adjacent `v0.2.7`/`v0.3.x` interaction-pipeline metrics and a Release `spice-bench` JSON harness | — | Versioned artifacts identify commit, toolchain, hardware, thermal state, workload, and date; live traces separate input-to-guest and receive-to-present stages |
| AIP-10 | done | Add an owned physical-message model and strict full-header submessage lists | — | List-only and main-plus-list ordering, bounds, ACK, fragmentation, and mutation tests pass |
| AIP-11 | done | Advance the serial barrier after processing and propagate channel failure | AIP-10 | Waiters remain blocked through handler work and terminate on success, failure, cancellation, or close |
| AIP-12 | done | Move the image cache to Session scope with ordered mutations and asynchronous resolves | AIP-11 | Cross-Display cache, lossless replacement, invalidation, FIFO, cancellation, and capacity tests pass |
| AIP-20 | done | Introduce a bounded canonical `PixelRegion` | AIP-12 | Random-mask differential tests and pathological 4,096-clip inputs pass |
| AIP-21 | done | Apply each wire draw command as one Surface transaction and revision | AIP-20 | Failure is atomic and `mutationTransactions == 1` |
| AIP-22 | done | Replace staged COPY_BITS with direction-aware O(1)-space copying and add bulk/fill kernels | AIP-21 | Eight-direction differential tests pass and `temporaryCopyBytes == 0` |
| AIP-23 | done | Remove IOSurface/Data backing ping-pong and resolve damage once per publication | AIP-21 | Full raw followed by a 1x1 CPU mutation records zero CPU materialization bytes |
| AIP-30 | done | Replace framer compaction and payload materialization with segments, `OwnedBytes`, `WireSlice`, and production Span parsing | AIP-23 | A contiguous body has zero copies and a fragmented body is coalesced at most once |
| AIP-31 | done | Decode LZ into one backing and optimize references and palette expansion | AIP-30 | spice-common fixtures remain bit-exact with one decoded-output allocation |
| AIP-32 | done | Split GLZ coordination from CPU workers and use a bounded codec `TaskExecutor` | AIP-31 | Independent images overlap execution while dictionary order, cancellation, and limits remain deterministic |
| AIP-33 | done | Parse Annex-B once and reduce VideoToolbox sample copies | AIP-30 | Copy counters improve and CoreMedia owner-lifetime tests pass on success, cancellation, and teardown |
| AIP-40 | done | Connect child channels with bounded concurrency | AIP-32 | Concurrency never exceeds four and failure leaves no connected transport behind |
| AIP-41 | done | Prepare independent Surface snapshots with bounded concurrency | AIP-32 | A blocked Surface does not prevent another from starting and emit order stays stable |
| AIP-42 | done | Replace realtime audio queues with preallocated rings | — | Realtime callbacks perform no linear queue movement or per-packet allocation |
| AIP-43 | done | Move blocking WebDAV filesystem work to a bounded executor | — | Slow I/O does not block an unrelated client while per-client order is preserved |
| AIP-44 | pending | Correlate input and display stages, then add interaction-aware low-latency frame selection | AIP-00 | Same-action paired traces reduce click/key/motion-to-visible p50 and p95 without weakening latest-only delivery, idle no-commit, drawable nonblocking, or the two-command GPU bound |
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
- The Session codec executor has width two, admits at most 64 pending jobs, and
  budgets at most 256 MiB of queued retained input. Display admission accounts
  the complete physical wire owner retained across a suspension, not only a
  small codec payload slice. Stateful MJPEG decoding retains its existing
  per-stream serial executor.
- GLZ keeps dictionary coordination in an actor, bounds the parsed program,
  charges the payload, operation/dependency storage, output reservation, and
  resolved dependency snapshots while waiting, and moves independent CPU work
  to bounded workers. Its internal dictionary-wait and executor admission also
  charge the complete physical wire owner retained by Display, exactly once per
  GLZ phase. Color overlap copies preserve long-distance phase while growing an
  initialized prefix instead of issuing one copy per short period.
- Advanced video scans Annex-B once into checked NAL ranges that share one
  immutable input owner and constructs AVCC in one exact allocation. Unchanged
  parameter sets compare through those ranges without materialization. CoreMedia
  borrows a stable retained `NSData` owner through a custom block source instead
  of receiving a second explicit payload copy. The free callback releases that
  owner exactly once across success, creation or submission failure,
  cancellation, teardown, and close; immutable diagnostics expose scan,
  allocation, copy, retain, release, and active-owner counts.

### Bounded connection concurrency

- Initial Session bootstrap and migration-target preparation use one shared
  child-channel connector with width four. The complete descriptor inventory is
  validated before any child transport is created. Transports are created in
  descriptor order; successful results transfer ownership only after every task
  completes and results are restored to that order.
- The first failure or parent cancellation stops admission and cancels the
  remaining tasks, but the task group is still fully drained. Every success
  observed before or after cancellation is closed before the error returns;
  each failed or pre-start-cancelled transport is closed at its owning boundary.
  Migration rollback leaves the source Session connected and no target
  transport active.

### Bounded WebDAV execution

- WebDAV filesystem work runs on a GCD-backed Swift `TaskExecutor` with width
  two, at most 64 pending jobs, and at most 256 MiB of server-retained request
  and response storage. Admission uses checked arithmetic and exposes immutable
  active, queued, retained-byte, completion, failure, cancellation, and
  rejection diagnostics.
- The server actor performs only bounded parsing, admission, generation checks,
  and per-client queue coordination. Each client has one ordered pump; unrelated
  clients may use separate executor permits, while one client's filesystem work
  and complete response send finish before its next request begins. Response
  transmission never occupies a filesystem permit. Incomplete input, parsed
  requests, and conservative encoded-response reservations share the retention
  limit through response-send completion.
- Session handling quick-submits native-backend work without waiting for
  filesystem or response I/O, so the WebDAV channel continues demultiplexing
  other clients. Client close, server close, Session-generation change, and task
  cancellation invalidate queued work; an active blocking syscall may return,
  but its late result must not send a response or revive client state.
- A failed response handoff terminates that generation of the client's pump and
  cancels its queued suffix. Session revalidates cancellation, supervision
  generation, and exact server identity after the final awaited response write
  before acknowledging delivery. The locally generated response-header envelope
  is reserved independently from the configurable inbound request-header limit.
- `HEAD` reads only file metadata, emits the exact file `Content-Length`, and
  never materializes file contents under the generated-header reservation.
  Depth-one `PROPFIND` enumerates direct visible children lazily, checks every
  property fragment against the complete response-body limit before retaining
  it, and retains at most 4,096 child fragments. It returns 507 at the first
  overflow and releases staged fragments as sorted XML is assembled.
- Closing a client cannot preempt a synchronous filesystem syscall or an
  already awaited response handoff. A newly admitted generation for the same
  client ID therefore retains its accounting but starts no worker until both
  the retired generation's active filesystem operation and response sender
  drain; unrelated clients remain independent. The synchronous compatibility
  API rejects same-ID reuse with its existing `invalidRequest` error during
  either retirement window because it cannot await the drain.
- Path resolution and its `FileManager` operation remain in one synchronous
  executor job with no suspension between them, preserving the existing root
  and symlink checks. Descriptor-relative filesystem hardening is a separate
  security item rather than an unrecorded expansion of AIP-43.
- The original public synchronous actor API remains unchanged through a bounded
  compatibility path. Session production traffic alone uses the package-only
  asynchronous pump, so AIP-43 does not expand or alter the public API.

### Bounded Surface snapshot preparation

- `DisplayFramePublisher` prepares independent Surface snapshots with a
  structured task-group width of two. Each flush captures at most 16 Surface
  requests, and the actor may coalesce at most 16 requests for the next flush
  while that batch runs: at most 32 lightweight request records and two active
  snapshot children exist. A child is admitted only when a previous child
  completes, so no unbounded task collection is created.
- Snapshot completion order never changes publication order. Results are
  restored to the publisher's stable Surface request order before stale,
  replacement, damage, prepared-frame, and emit state is evaluated; emit
  remains serial. One Surface returning no snapshot does not cancel independent
  Surface work.
- The publisher retains at most one preparation-manager task in addition to its
  two structured snapshot children. Cancellation invalidates the publisher
  generation, directly cancels that manager so cancellation propagates to all
  admitted children without waiting for a natural completion, stops further
  admission, and awaits the manager's complete drain before returning. Every
  late result is suppressed. Surface removal and recreation retain their per-ID
  invalidation check. The `SurfaceStore` remains the owner of per-Surface
  operation leases and atomically selects the revision, constructs its
  immutable snapshot, and transfers publication damage. Its FIFO reservation
  wait is cancellation-aware: cancellation before registration never enters
  the queue, cancellation while queued removes and resumes that exact waiter,
  and grant racing cancellation is claimed or released exactly once before
  snapshot materialization. Waiter registration is also its ownership
  linearization point: after any pre-registration suspension it atomically
  rechecks the Surface, directly claims it if the previous holder has already
  released, and otherwise joins the FIFO. A cancelled publication rechecks
  cancellation after snapshot preparation and cannot transfer publication
  damage; teardown never abandons an acquired lease.
- Publication damage transferred into a concurrently prepared snapshot remains
  under an exactly-once lease until that snapshot's ordered emit returns.
  Successful emit commits the lease. Cancellation, stale validation, or any
  other path that skips emit restores it through the same per-Surface operation
  serialization; restoration merges into later same-lifecycle damage instead
  of overwriting it and drops only damage belonging to a destroyed lifecycle.
  Publisher cancellation drains snapshot children and all outstanding damage
  restorations before returning, including frames prepared behind a suspended
  earlier emit.

### Preallocated realtime audio handoff

- Playback and capture each use a preallocated 16 MiB logical PCM queue with at
  most 262,144 metadata slots. Playback may own one additional 16 MiB staging
  bank so a producer never copies packet payload while holding the realtime
  render gate; diagnostics report queued, staging, and total ownership
  separately. Capture remains single-bank.
- Playback uses a pull render source. The realtime callback consumes published
  ring bytes or zero-fills underflow; it does not create a `Task`, allocate an
  `AVAudioPCMBuffer`, move an array prefix, or materialize packet `Data`.
  Producers serialize, copy ordinary packets into an unpublished active-bank
  range, and publish only metadata under the short gate. Overflow is prepared
  in the inactive bank and committed by one O(1) bank swap plus startup reset.
  Close rejects a late staged commit, reset cannot revive stale PCM, and FIFO
  order survives wraparound and concurrent producer admission.
- The capture tap validates the complete callback before publication, copies
  fixed 1,024-frame interleaved or planar chunks into one preallocated input
  buffer, converts through one ratio-sized reusable output buffer, and writes
  PCM into the ring without callback-owned allocation. Capture metadata is
  sized from the output-frame byte budget, not an assumed minimum callback
  shape. Realtime failures retain a fixed typed token; `String` formatting and
  packet `Data` materialization occur only on the async drain side.
- A two-phase capture dequeue lease keeps allocation and copy outside the
  producer mutex while preventing overwrite of leased bytes. Each drain is
  bounded to the queued-slot snapshot taken at entry, so continuous production
  cannot make one async drain unbounded. Wraparound uses at most two copies and
  overflow/drop accounting uses checked, deterministic limits.

## Measurement and acceptance

Perceived interaction latency takes precedence over aggregate throughput. Use
this optimization and acceptance order:

1. End-to-end input: host click, key, or motion receipt to wire-send completion,
   guest/protocol ACK where one exists, and the corresponding visible response.
2. Display pipeline: frame receive to Surface ready, latest-revision selection,
   Metal commit, and drawable presentation.
3. Visual quality: clarity and scaling at the same guest workload.
4. Resource guardrails: CPU and RSS must not regress materially, but neither is
   a proxy for interaction latency.

Every live comparison must replay the same timestamped interaction and establish
an unambiguous causal endpoint. The SPICE mouse-motion ACK has a zero-length body
and no correlation token, so it is only an optional endpoint for the guest/ACK
subsegment, never the visible endpoint. Every motion observation admitted to an
input-to-visible p50 or p95 requires its own unique guest-rendered marker and the
matching presented revision, including serialized probes.

An ACK may identify one motion action's guest/ACK subsegment only when the
fixture uses a fresh Inputs channel/generation that has never sent motion, or a
deterministic equivalent clean epoch, and keeps exactly one probe outstanding.
Before starting its wire send, pre-arm that same-generation probe, but do not
complete or correlate its ACK subsegment until the wire-send completion
timestamp is recorded. If a same-generation ACK arrives first, buffer it and
release it only at that post-send linearization point. The next motion probe may
not start until the current ACK subsegment is resolved or the probe fails. An
ACK observation may therefore fall between the send-started and send-completed
timestamps; the guest/ACK subsegment completes at
`max(sendCompletedNs, motionAckNs)`. This does not change pre-arming, buffered
early-ACK, clean-epoch, or generation-retirement rules. An
ACK captured by an old or previous generation, or arriving after close or
migration retirement, is discarded and can never satisfy the current
generation. Never attribute concurrent outstanding motions from ACK order; their
visible markers remain the only causal endpoints. Keyboard and button messages
have no general guest ACK and likewise always use a unique visible marker. Do
not infer causality by adding unrelated aggregate histograms or pairing an input
with whichever frame happened to arrive next.

Host display receive may be observed after `sendStartedNs` but before the send
task records `sendCompletedNs`. This overlap remains causal: validation requires
both observations to be no earlier than send start, while the derived
post-send-to-display segment is clamped to zero. A display observation earlier
than send start remains invalid. The capture therefore linearizes host input
and send start before entering the wire send, admits exact frame observations
from that point, and records send completion separately when the continuation
resumes. A same-generation motion ACK may be buffered across that boundary;
the completion stage may confirm the same ACK but cannot substitute a different
one or complete twice.

The Rocky fixture now provides the first causal-trace slice without changing
display scheduling. `control.sh arm <click|key|motion> <token>` pre-arms one
strictly unique 16-lowercase-hex token. Only the next matching real guest input
consumes it, records guest-received time, and draws a fixed high-contrast ROI
whose payload includes the token, guest marker revision, and SHA-256 checksum.
The guest state machine rejects an illegal/reused token and a concurrent arm;
autonomous animation cannot consume the arm. Every run reserves a normalized
`input-events.jsonl` path, and the package-only Codable schema derives validity
from the complete host-input/send, guest-marker, display, selection, commit,
presented, and frame-identity evidence. Guest and host monotonic clocks are
validated only within their own domains. The guest marker revision is not the
host frame revision and must be correlated by captured marker pixels and the
matching presented delivery, not by numeric equality.

Before each real arm, the host sends a unique random 128-bit lowercase-hex
control barrier and waits for its exact serial-log echo. It records the arm
response boundary only after that echo, so delayed output from a prior
invocation cannot be mistaken for the current accepted or rejected result. A
barrier timeout fails without sending the arm and never exposes the SPICE
ticket.

The AIP-00c harness slice adds a serialized `control.sh trace` transaction on
that same lock and barrier. Sync, arm acceptance, and the exact action/token
`guest_received` followed by `marker_drawn` at one marker revision share a
single bounded retry budget. Duplicate, malformed, reversed, mismatched, or
missing evidence fails closed; unrelated serial traffic cannot satisfy the
transaction. On macOS, a package-only cancellation-safe continuation waits for
the current capture's selected and committed identity to be accepted by the
actual presented callback. Presentation before waiter registration is cached,
unrelated in-flight identities cannot wake it, and the wait neither finishes
nor appends the trace. This is a harness synchronization seam, not a pacing
change.

The SwiftPM test-host window gate was unsuitable for this live closure because
WindowServer occlusion could prevent real framebuffer demand and teardown
could race late AppKit callbacks. The replacement is the dedicated
`spice-live-interaction` foreground AppKit executable. It hosts the unchanged
`SpiceDesktopView` in a real visible window, requires exactly one visible
subscription and an initial Metal commit/present before arming, then combines
the streamed guest transaction with the package exact-presentation wait and
schema-2 collector. Its failure path finishes with the assembler's derived
missing-stage reason before best-effort publication. This adds no polling to
the presentation path, changes no scheduling policy, and retains latest-only,
idle-no-commit, and GPU in-flight-at-most-two invariants. The harness sends its
click directly through the session after arm, so a successful live run proves
marker-to-exact-frame-to-presented closure, not AppKit input queue latency.

The unlocked 2026-08-30 run closed that exact live-correlation seam. It also
showed two measurement hazards that remain outside AIP-00 completion. First,
`CAMetalDrawable.presentedTime == 0` is a dropped/not-presented sentinel, not a
valid timestamp. The presenter now permits one authoritative latest-only retry
for the same selected revision when demand remains visible; it never fabricates
a callback time, submits an idle frame, or exceeds two commands in flight.
Second, publishing the 176 marker cells as per-cell X request pairs perturbed the
very frame stream being measured. The guest now constructs the complete native
`XImage` in client memory and publishes it with one `XPutImage` followed by
`XSync`; the binary-grid bytes, descendant selection, terminal barrier, and ACK
ordering are unchanged.

Seven atomic-marker click records bind the guest token to one exact frame and
presented callback. Their nearest-rank `ready -> selection` p95/max is only
0.043 ms, versus 8.044 ms in the immediately preceding ten-record multi-request
fixture run. This removes the present evidence for immediately changing the
production pacing policy: the earlier one-tick tail can be produced by the
measurement workload itself. The atomic run still has `input -> presented` p95
213.059 ms and eight additional cold-start attempts failed before arm after two
commits produced no presented callback. Those failures append no interaction
record. The seven direct-click observations are directional only: they do not
cover AppKit input receipt, key or motion, paired versions, or the required run
clusters, and therefore neither complete AIP-00 nor admit AIP-44.

The AIP-00d harness extends that closure to one fixed, non-configurable
`click -> key -> motion` cluster in one already-visible window and Session.
`SWIFTSPICE_LIVE_CLUSTER_ID` is a mandatory canonical 16-digit lowercase-hex
identity; it deterministically derives three version-independent pair IDs,
tokens, and checksums. A step cannot arm until the preceding step has exact
presented evidence and its one current JSONL line has been appended remotely.
Markerless drawable drops and command-failure retries are rebound only to their
own identity and cannot poison a later target marker; an exact-marker duplicate
without an outcome remains invalid. Relative motion requires a clean-epoch
post-send SPICE ACK, while absolute tablet `mousePosition` has no such protocol
ACK and remains causal through guest-received, marker-drawn, and exact-presented
evidence.

The unlocked Rocky run at
`/home/beribeli/swiftspice-aip00b/perf-ab/logs/20260830T021418Z.037hAL`
contains the successful cluster `0000000000000008`: click, key, and absolute
motion are all schema-2 `valid=true` records from one process and Session.
Their directional host-input-to-presented times are 197.254, 107.894, and
216.268 ms respectively; ready-to-selection is 0.010, 8.195, and 0.012 ms.
Earlier cluster attempts in the same retained run exposed and now guard the
markerless-retry attribution bug, one zero-presented pre-arm cold start, and the
invalid assumption that absolute motion produces a relative-motion ACK. This
closes the current-version multi-action smoke gate, but it still bypasses AppKit
input receipt and is not the required ten-cluster paired `v0.2.7`/current
artifact. AIP-00 and AIP-44 therefore remain open.

AIP-00e makes the paired artifact a fail-closed input rather than an informal
post-processing convention. One specification declares exactly ten canonical
cluster IDs, the baseline and candidate versions, pointer mode, and a
counterbalanced 20-run sequence. Acceptance requires exactly 60 valid schema-2
records: one contiguous `click -> key -> motion` run for each cluster/version,
20 globally unique run IDs, and plan-derived pair IDs, tokens, checksums, action
orders, and pointer-mode ACK semantics. Missing, duplicate, reordered, aliased,
extra, or cold-start-invalid observations reject the whole artifact; they are
never filtered before statistics. Reports retain every host-domain stage,
compute Hyndman-Fan type-7 p50/p95 by action/version, and compute signed
candidate-minus-baseline deltas for the same cluster/action. CPU and RSS require
complete run coverage but remain independent guardrails and cannot affect
latency pairing. This deterministic gate does not yet provide the `v0.2.7`
measurement overlay or the required live 10-cluster artifact, so AIP-00 remains
in progress.

The live Rocky marker also requires the pinned guest Xorg input driver
`xf86-input-libinput=1.5.0-r0`. A guest image without that driver may accept
SPICE keyboard or pointer traffic without emitting the XI2 event consumed by
the marker monitor. The driver version is therefore part of the guest build
manifest and a required startup key, not an unrecorded host assumption.

The Rocky run
`/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T170315Z.cfDtZd`
validated this guest-side repair. eudev discovery allowed Xorg/libinput to
register the Virtio keyboard and mouse and the later hotplug SPICE tablet. A
Release mode-aware probe then produced both `guest_received` and `marker_drawn`
for key token `4444`, motion token `5555`, and click token `6666`; the motion
exercise also observed two protocol ACKs. This proves client input reached the
guest X server and caused the marker draw call. It does not prove that the
marker pixels entered one exact SwiftSpice frame revision or that AppKit
presented that delivery.

That run used a separate ordinary marker xterm which a fullscreen static or
animated workload could stack above even after the renderer acknowledged its
write. It is therefore draw-call evidence, not proof that marker pixels were
visible. The fixture now renders the reserved marker ROI inside the active
fullscreen workload xterm itself, keeps subsequent animation frames outside
that ROI, and acknowledges only after an xterm terminal-response barrier. A
byte-state parser uses one absolute monotonic half-second deadline, ignores
unrelated input including printable `n`, and accepts only exact `ESC [ 0 n`.
EOF, malformed-only input, or timeout produces no ACK. The
agent's longer two-second bounded FIFO wait therefore expires only after the
renderer has either acknowledged or definitively declined the event; a late
revision from another writer may still enter the FIFO, but the bounded reader
drains nonmatching revisions and never lets one satisfy or poison the current
request. A monotonic nanosecond deadline is recorded before request publication; every
stale-record read uses only the remaining total time and never resets the
timeout. A timed-out terminal-status query taints that renderer until a later
marker, before drawing, sends the distinct cursor-position query `ESC [ 6 n`
and receives an exact `ESC [ <row> ; <column> R`. Terminal output ordering makes
that response a resynchronization fence past the old DSR; a late old
`ESC [ 0 n` is drained as unrelated input and cannot satisfy the fence. A
failed fence leaves the renderer tainted and emits no draw or ACK. The renderer
holds one request FIFO read/write descriptor for its
entire main loop, including while drawing and waiting on the terminal barrier,
so a next request published during processing remains queued for its next read.
The agent also opens the request FIFO read/write, writes one small fixed record,
and closes it immediately. Without a renderer, open cannot block and closing
the final endpoint discards the unconsumed request before a future workload can
observe it. The wait treats a missing acknowledgement or wrong
marker revision as a failed event and releases the guest marker lock; it never emits
`marker_drawn` from an unacknowledged write. A
fresh live run must still bind those pixels to the exact host frame and
presentation identities below; the stacking repair does not upgrade the older
run into input-to-visible evidence.

The guest XI2 monitor admits only RawKeyPress, RawButtonPress, and RawMotion;
the delivered counterpart for the same physical input is ignored and cannot
consume a subsequently armed token. A dedicated serialized agent worker keeps
the XI2 reader draining while a marker is rendered. Key and click observations
remain FIFO; a motion ownership token is created before the first RawMotion is
queued and remains set after that call returns. Before the next arm, its unique
invocation sync requests XI2 source rotation. The native source first opens one
X connection, selects only RawKeyPress, RawButtonPress, and RawMotion on the
root window, completes an `XSync` round trip, and atomically publishes readiness.
The monitor terminates the old helper, drains all stdout already published
through EOF, and closes that X connection so unread upstream events are
discarded with the generation. It waits for the replacement helper's same
application-level readiness before publishing a checkpoint behind every old
agent call; the worker clears motion ownership
and acknowledges only after reaching it. Only then may the host send the arm.
Thus neither an upstream X backlog nor reader scheduling can move an old queued
record into the next arm epoch, and no arbitrary quiet-period sleep defines the
boundary. One total bounded checkpoint budget covers monitor/source startup and
worker acknowledgement; the phases cannot each consume a fresh timeout. Guest event
timestamps use a statically
linked `clock_gettime(CLOCK_MONOTONIC)` helper recorded as
`guest_marker_clock=clock_gettime-monotonic-v1` in the build manifest. Coarse
`/proc/uptime` text must not be scaled and represented as nanosecond evidence;
an unavailable or malformed monotonic sample invalidates the event. The
manifest must also record `guest_xi2_monitor=native-xi2-select-sync-v1` and the
pinned libXi/libX11 runtime versions. The evidence log below records the native
helper's exact-source Rocky live closure; it still does not bind marker pixels
to an exact SwiftSpice frame/delivery and AppKit presented callback.

This is an executable fixture/schema seam, not completion evidence. The local
schema-2 collector now binds a decoded binary-grid marker to one exact frame
identity and the same delivery's presented callback, and atomically retains
both valid and attributable-invalid records. A separate Rocky run still must
exercise that path with real captured pixels and populate its per-event JSONL
record. Until that live gate succeeds, missing or
ambiguous marker/presented evidence is invalid, and no input-to-visible latency
or improvement claim may use these records.

The next gate is an independent Rocky fixture using
`guest_marker_roi=binary-grid-v1` and schema 2 to prove exact marker
pixel-to-frame-generation/revision/delivery and AppKit-presented binding,
followed by paired `v0.2.7`/`v0.3.x` traces. Only those paired results may decide
whether ready-to-selection should use an interaction-aware immediate path or an
adaptive display-link policy. Either choice must retain latest-only delivery,
zero idle commits, at most two GPU commands in flight, and CPU/RSS guardrails.

The first host-correlation slice lands only the fail-closed Swift evidence
pipeline. A Display publication carries the `messageReceivedAt` and
`surfaceReadyAt` belonging to its exact emitted revision; a prepared frame that
covers a pending replacement uses the replacement's timing and never inherits
the older request's timestamps. The package-only marker detector reads actual
BGRA storage through one synchronous, closure-scoped bounded ROI borrow. For
IOSurface publications it read-locks only while sampling the top-left marker
candidates at aligned origins 8 through 32 and does not materialize or cache a
full-frame CPU copy; Data-backed
fallbacks use their existing bytes. The correlation identity contains desktop
generation, display channel ID, surface ID, Surface lifecycle generation,
frame revision, and delivery sequence. Selection, the Metal command-buffer commit-call
boundary, and `CAMetalDrawable` presentation all retain that same identity. A
desktop snapshot's envelope delivery sequence orders cursor, pointer-mode, and
latest-state coalescing independently; only the sequence owned by the retained
frame publication participates in the frame identity. A control-only merge
therefore cannot relabel an older frame, while a real frame publication obtains
a new frame sequence. A GPU-busy or drawable-unavailable retry restores the selected delivery's
original ready instant and nanoseconds rather than manufacturing a new ready
event. Surface destruction or direct lifecycle replacement retires that
display-channel/surface lifecycle, so an old drawable cannot complete a
recreated surface's trace; a trace already presented before retirement remains
historical evidence. The presented stage uses the drawable's actual
`presentedTime` mapped into the host monotonic clock, while MainActor
serialization keeps its trace mutation after the corresponding Metal
`commit()` call. The commit timestamp is stored at the immediately preceding
call boundary after every handler has been installed, with no diagnostics or
external work between that store and `commit()`; completion can therefore
never observe a missing timestamp. A missing marker, ambiguous ROI, duplicate
identity,
retired generation, latest-only replacement, CPU fallback without a presented
callback, or missing input remains invalid. Invalid replacement records still
retain the stages and identity actually selected so a failure can be diagnosed
without reassigning the older marker.

The guest renderer and Swift detector now share the versioned
`binary-grid-v1` layout, and the build manifest makes that capability a startup
requirement. Normalized schema 2 includes `desktop_generation`,
`display_channel_id`, `surface_id`, and `marker_checksum`; a bounded
mode-0600 writer uses a sidecar lock and same-filesystem fsync/replace to append
both valid and attributable-invalid records without partial lines. The fixture
container/image/base/ports can be strictly overridden so the AIP-00b gate does
not inspect, stop, or reuse the established performance endpoint. Until a new
live gate binds captured pixels to the exact
presented delivery, this internal seam is not completion evidence and supports
no input-to-visible latency or scheduling conclusion.

An end-to-end request-to-presented measurement may summarize user experience,
but it does not identify which path caused a change. In particular, a capture
with no input events cannot support a conclusion about the input queue. After
latency, compare visual clarity at the same guest workload and scaling; treat
CPU and RSS only as regression guardrails.

The 2026-08-28 Maspice adjacent-run observation against the same guest provides
directional evidence, not the paired artifact required to complete AIP-00:

| Observed interval | `v0.2.7` | `v0.3.0` | Direction |
| --- | ---: | ---: | --- |
| Surface ready to frame selection p95 | 0.2 ms | 12 ms | Regression; highest-priority display-path target |
| Surface ready to frame selection max | 70.8 ms | 22.2 ms | Tail maximum improved while the p95 distribution shifted later |
| Snapshot preparation p95 | 4.0 ms | 0.2 ms | Improvement |
| Selection request to presented p95 | 100 ms | 33 ms | Presentation improvement; this interval does not start at input |
| Warm CPU | 12.51% | 12.37% / 12.23% | Approximately unchanged; guardrail only |

The local samples are
`/private/tmp/maspice-swiftspice-027-controlled.sample.txt` and
`/private/tmp/maspice-swiftspice-030.sample.txt`. They are host-local supporting
evidence and must not be committed or treated as a reproducible release
artifact. The `v0.3.0` diagnostic interval used for the reported timings
contained no input event or correlation token, so neither the 12 ms p95 nor the
request-to-presented change can be attributed to an input queue. RSS also
remains a guardrail for the final controlled paired runs rather than a target
inferred from these samples.

Code and sample review narrow the hypotheses without proving one:

- `SpiceDesktopPresentationPacingPolicy.readyBecameAvailable()` selects an idle
  update immediately, but an update arriving while the one-shot display link is
  active waits for the next tick. A 12 ms histogram result means the p95 landed
  in the `(8, 12]` ms bucket; without refresh-rate and arrival-phase data it does
  not prove that a response always waited a complete frame or missed two ticks.
- In the `v0.3.0` baseline, `SpiceDesktopReadyLatch.pendingSince` records the
  first empty-to-ready transition, so a newer coalesced revision inherits that
  timestamp. This package-only slice instead records the `readyAt` of the
  selected/latest strictly accepted revision and rejects an unsolicited exact
  duplicate generation/delivery identity without changing the timestamp or
  re-waking the latch. An explicit authoritative `requestLatest()` redraw gets
  a new delivery identity even when its frame revision and generation are
  unchanged, preserving retry and resize redraws. The slice does not change
  display-link pacing. This makes the diagnostic revision-accurate, not a
  latency improvement. Live paired external artifacts are still required to
  complete AIP-00 before changing AIP-44 scheduling.
- `SpiceMetalFrameView.canPresentWithoutBlocking` currently checks only the
  two-command GPU slot. The `v0.3.0` sample contains 31 one-millisecond samples
  in `currentDrawable → nextDrawable → semaphore_timedwait`, versus about nine
  drawable-acquisition samples and no sampled semaphore wait in the controlled
  `v0.2.7` capture. Sampling counts are not event counts or per-stall durations,
  but they require a separate nonblocking drawable-capacity gate.

The next display-latency study must compare a low-latency selection path for
correlated interactive updates with an adaptive display-link policy. Sweep
arrival phase across manual 60 Hz and 120 Hz ticks; prove a steady-state update
is selected on the first eligible tick, never the second, and record the
selected revision rather than only the oldest coalesced-ready time. When a
correlated interactive revision becomes ready and both a command slot and a
drawable are demonstrably available without blocking, evaluate immediate
selection even while the pacing link is active. Otherwise retain tick pacing
and retry only the latest revision. Do not restore per-frame SwiftUI updates or
unconditional Metal commits.

Package-only deterministic seams may inject the monotonic clock, manual display
ticks, input/revision trace tokens, drawable availability, command completion,
and presented callbacks. Required tests cover idle immediate selection,
steady-state tick-phase sweeps, first-ready versus selected-revision-ready
timing, serialized one-outstanding mouse-motion ACK probes, rejection of
concurrent ACK-only motion attribution, a prior-generation late ACK after
close/migration that cannot complete the current probe, and deterministic ACK
interleavings before, during, and after wire-send completion. The early-ACK case
must prove pre-arming buffers only a same-generation ACK and that no ACK
subsegment completes before the send-completion timestamp. Every serialized or
overlapping motion observation, plus every key/button observation, must prove
unique visible-marker correlation. The remaining matrix covers GPU-busy and
drawable-unavailable latest-only retry, zero drawable access/commit on empty
ticks, and strict distinction between command completion and compositor-visible
presentation.

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

The AIP-90 live decision uses ten pairs, meaning 20 separate 30-second runs: one
`v0.2.7` run and one candidate run per pair. Both members replay the same
relative action schedule and action tokens at a fixed cadence, beginning from
the same declared guest reset point. Before collection, declare a counterbalanced
order with five baseline-first and five candidate-first pairs; do not choose or
change order after observing results. Each action class must retain at least 50
valid causally matched observations per run and 500 total per version; a missing
marker, ambiguous motion ACK, timeout, or dropped pair is invalid rather than
silently reassigned. Report the action-specific input-to-visible p50 and p95 and
the input, guest/ACK, display, commit, and presented segments above.

Interaction latency is the primary pass/fail gate. For each of click, key, and
motion and for each of p50 and p95, perform exactly 10,000 paired hierarchical
bootstrap resamples with SplitMix64 and base seed `0x5350494345414950`, not a
runtime-selected count. The six metrics have this fixed
index order: click p50, click p95, key p50, key p95, motion p50, motion p95.
Metric index `i` uses its own stream initialized as
`SplitMix64(seed: baseSeed &+ UInt64(i))`; the artifact records the PRNG, base
seed, index order, and resample count.

Map every SplitMix64 output to a bounded index with the same unbiased rejection
rule. For a `UInt64` bound `n > 0`, compute
`threshold = (0 &- n) % n` using wrapping arithmetic; draw the next `UInt64` `r`
until `r >= threshold`, then use `r % n` as the index. Every rejected `r`
consumes that metric's stream. A zero bound is undefined and fails the resample.
Use this exact mapping for both run-cluster selection and paired-token selection;
do not substitute floating-point scaling, truncation, or another bounded-random
implementation.

For each metric resample, sample the ten run-pair clusters with replacement.
Each time a cluster is selected, draw with replacement exactly that cluster's
valid paired-token count; a token selects its baseline and candidate observation
together as one pair. Pool the selected baseline observations and candidate
observations separately, compute each version's quantile with Hyndman-Fan type 7
interpolation, then record the candidate/baseline quantile ratio. Form the
two-sided 95% percentile confidence interval from the ratio distribution, again
with type 7 interpolation at 0.025 and 0.975. A nonpositive or nonfinite baseline
quantile, a nonfinite ratio, or any undefined resample fails the gate rather than
being removed. The candidate passes only when the upper confidence endpoint is
at most 1.10 for all six action/percentile combinations. Insufficient valid
samples fails the gate; improvement in one action or percentile cannot offset a
regression in another.

Only after that primary gate passes does AIP-90 check clarity and scaling, then
resource guardrails. Average FPS or CPU cannot substitute for the
interaction-latency result. Existing guardrails remain: fps lower bound 0.95;
CPU-per-frame upper bound 1.10; RSS upper bound 1.15; and zero stale
publications, pool exhaustion, GPU errors, idle commits, or violations of the
two-command in-flight limit. Real-window 1080p/4K at 60/120 Hz and audio-device
behavior remain separate acceptance gates.

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
| AIP-00 | 2026-08-28 | Local Maspice adjacent run | `/private/tmp/maspice-swiftspice-027-controlled.sample.txt`; `/private/tmp/maspice-swiftspice-030.sample.txt`; same guest; ready-to-selection p95 0.2 ms to 12 ms (max 70.8 ms to 22.2 ms), snapshot p95 4.0 ms to 0.2 ms, selection-request-to-presented p95 100 ms to 33 ms, and warm CPU 12.51% to 12.37% / 12.23% | Directional host-local evidence only. The reported `v0.3.0` diagnostic interval contained no input event or correlation token, so it cannot measure or explain input-queue latency. The samples are not committed artifacts and do not complete AIP-00. |
| AIP-00 | 2026-08-29 | Rocky 9 live marker run | `/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T170315Z.cfDtZd`; eudev/Xorg/libinput registered Virtio keyboard/mouse and hotplug SPICE tablet; Release mode-aware key `4444`, motion `5555`, and click `6666` probes each emitted `guest_received` plus `marker_drawn`; motion ACK count 2 | Guest-causal subpath evidence only: client input reached guest X and invoked the marker renderer. The run does not bind marker pixels to an exact SwiftSpice generation/revision/delivery or AppKit presented callback, so it does not complete AIP-00 or justify a scheduling change. |
| AIP-00 | 2026-08-29 | Rocky 9 rebuilt guest marker run | `/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T194358Z.TQ3mft`; build manifest records `guest_marker_clock=clock_gettime-monotonic-v1` and `guest_linux_virt=6.12.107-r0`; Release probe exited 0 after 42 frames and two motion ACKs; token `eeeeeeeeeeeeeeee` recorded `guest_received=53621746290 ns` and `marker_drawn=53628063503 ns`, a 6.317213 ms guest-clock delta, with no marker error | Confirms only the guest-causal draw/ACK subpath. Marker pixels are not yet bound to an exact SwiftSpice frame revision and AppKit presented callback, so this evidence neither completes AIP-00 nor supports an AIP-44 scheduling change. |
| AIP-00 | 2026-08-29 | Rocky 9 arm-barrier retry run | `/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T201148Z.r0vGwi`; sync `b90af807995470a1595ec1a140120859` preceded `PERF_ARMED` for click token `abababababababab`, followed by `guest_received=24953841014 ns` and `marker_drawn=24959354130 ns`; Release probe exited 0 after 42 frames and two motion ACKs with no marker error; retrying the same token used distinct sync `c61a9dcca1e180bdf44d9a76af72a34f` and returned `duplicate_token`, with no stale `PERF_ARMED` accepted | Live evidence for the per-invocation log barrier, retry rejection, and guest-causal marker subpath only. It still does not bind marker pixels to an exact SwiftSpice frame revision and AppKit presented callback, so it does not complete AIP-00 or support an AIP-44 scheduling change. |
| AIP-00 | 2026-08-29 | Rocky 9 motion-epoch drain run | `/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T204616Z.Q0jo6t`; rebuilt Alpine guest and restarted endpoint; first Release probe exited 0 with 42 frames and two motion ACKs, and token `1111111111111111` recorded `guest_received=29908152175 ns` then `marker_drawn=29918028916 ns`; the next sync/checkpoint armed token `2222222222222222`, which remained only `PERF_ARMED` after one second with no new input and no marker/control error; a second Release probe then exited 0 with 15 frames and two motion ACKs and only its new burst produced `guest_received=77938920509 ns` then `marker_drawn=77960725095 ns`. After the host-test transport fix, the exact-source rebuild at `/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T210655Z.rXLQJS` again produced 42 frames, two motion ACKs, and token `3333333333333333` at `guest_received=23044223211 ns` then `marker_drawn=23053993151 ns`, with no marker/control error. | Live evidence that RawMotion queued by the first exercise burst did not cross the explicit event-FIFO/worker checkpoint and consume the next arm. The run also exercises the persistent renderer request FIFO and exact terminal barrier through successful marker revisions. It remains guest-causal evidence only: marker pixels are not bound to an exact SwiftSpice delivery and AppKit presented callback, so AIP-00 and AIP-44 remain open. |
| AIP-00 | 2026-08-29 | Rocky 9 exact-source rotation/resync run | `/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T215310Z.2MwTiI`; local and remote monitor SHA-256 both `69790792ad1df7c6d792055098a2a3f1c1e54276fbe8a90078782060a4b7719b`, and renderer SHA-256 both `0dabd04339fb7d5cc27debe49cbee9a2eeae3f2fa14903851633e544cd05fb11`; the manifest records kernel hash prefix `5d1248...`, initramfs hash prefix `2253b8...`, and pinned `xf86-input-libinput=1.5.0-r0`, `xinput=1.6.4-r2`, and `xterm=399-r0`. Probe 1 exited 0 after 42 frames and two motion ACKs; token `4444444444444444` recorded `guest_received=90816603923 ns` then `marker_drawn=90826034950 ns` (9.431027 ms). After the adjacent sync, token `5555555555555555` remained only `PERF_ARMED` for about nine seconds; probe 2 then exited 0 after 15 frames and two motion ACKs and recorded `guest_received=143585443088 ns` then `marker_drawn=143607414779 ns` (21.971691 ms). The log contains no `PERF_ERROR`. | Exact-source live evidence for source-generation rotation, the adjacent idle arm boundary, and the guest marker draw/ACK subpath. It still does not bind marker pixels to an exact SwiftSpice frame revision/delivery and AppKit presented callback; it therefore does not complete AIP-00 or justify an AIP-44 scheduling change. |
| AIP-00 | 2026-08-29 | Rocky 9 native XI2 application-ready run | `/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T221334Z.L7UYBw`; local and remote source hashes match: `xi2-event-monitor.c` SHA-256 `219277b6af523c2600a0aea8d80eb9e45998907b90891d329b34cfab487f1070` and `input-marker-monitor.sh` SHA-256 `aee0d9ae049bfb155b378b44462030aee728a4f6fbb86e46efd128de9f00d96c`. The manifest records `guest_xi2_monitor=native-xi2-select-sync-v1`, `guest_libx11=1.8.11-r0`, `guest_libxi=1.8.2-r0`, kernel SHA-256 `5d124820329f4c664cdb61635ada850e89a6ac1aea171a7079daa25add349289`, and initramfs SHA-256 `ba424f6b8084e436876a1f5c60312f3f0ce29c321ebf8a940262a5070d9ff344`. Probe 1 exited 0 after 42 frames and two motion ACKs; token `6666666666666666` recorded `guest_received=35525744079 ns` then `marker_drawn=35535631312 ns` (9.887233 ms). After the adjacent sync, token `7777777777777777` remained only `PERF_ARMED` for about 14 seconds without new input; the subsequent probe exited 0 after 11 frames and two motion ACKs and recorded `guest_received=85115646987 ns` then `marker_drawn=85136868964 ns` (21.222977 ms). Neither probe logged `PERF_ERROR`. | Live closure that the native helper reaches application readiness only after `XISelectEvents` and its `XSync` round trip, while source rotation preserves the adjacent idle arm boundary. This remains guest-causal marker draw/ACK evidence: marker pixels are not bound to an exact SwiftSpice frame revision/delivery and AppKit presented callback, so it is not a completed input-to-visible latency measurement and does not complete AIP-00. |
| AIP-00 | 2026-08-29 | Isolated AIP-00b guest-causal smoke run | `/home/beribeli/swiftspice-aip00b/perf-ab/logs/20260829T061937Z.9FuYes`; the separately named fixture used host ports `5945`/`5946` and captured its arm, matching guest-received event, and marker-drawn event | Guest-causal smoke evidence only. This run predates the AIP-00c exact-presentation wait harness and does not bind marker pixels to an exact SwiftSpice delivery and AppKit presented callback. It is neither AIP-00 completion nor an input-to-visible latency result. |
| AIP-00 | 2026-08-29 | AIP-00c foreground readiness attempts | The Release `spice-live-interaction` executable was run against the isolated `5945`/`5946` endpoint through local forward `15945`, first directly and then from an ad-hoc-signed minimal app bundle with an explicit system activation request. Every attempt failed before arm with the same safe readiness state: `window_visible=true`, `window_occluded=true`, `hosting_hidden=false`, `bounds=960x540`, `subscriptions=1`, `visible_subscriptions=0`, `commit_delta=0`, and `presented_delta=0`. The collector at `/home/beribeli/swiftspice-aip00b/perf-ab/logs/20260829T061937Z.9FuYes/input-events.jsonl` remained zero bytes. | The current Mac WindowServer execution session did not grant a genuinely visible surface, so the harness correctly refused to create synthetic demand or send an input. This is an environment-blocked live gate, not a SPICE failure or AIP-00 completion. Repeat from an interactive, unlocked Mac session before accepting marker-to-presented evidence or making an AIP-44 scheduling decision. |
| AIP-00 | 2026-08-30 | AIP-00c unlocked exact-presentation run | `/home/beribeli/swiftspice-aip00b/perf-ab/logs/20260829T141056Z.dWq0dC`; ten adjacent schema-2 `v0.3.3` direct-click records, marker revisions 9 through 18, all `valid=true`; nearest-rank p50/p95: input-to-presented 137.675/215.805 ms, input-to-display-receive 81.659/165.250 ms, Surface-to-selected-ready 29.375/34.058 ms, ready-to-selection 0.039/8.044 ms, selection-to-commit 0.330/0.830 ms, and commit-to-presented 22.841/32.154 ms | First live closure from a unique guest input token and decoded marker through exact SwiftSpice frame identity, selected-ready, selection, Metal commit, and actual AppKit presented callback. The guest used the older per-cell X request marker, so visible intermediate updates could perturb the display phases. Direct session input bypasses AppKit receipt; this single-version click slice does not complete AIP-00 or prove an AIP-44 scheduling change. |
| AIP-00 | 2026-08-30 | AIP-00c atomic-marker directional run | `/home/beribeli/swiftspice-aip00b/perf-ab/logs/20260830T011820Z.L5b0o6`; seven adjacent schema-2 `v0.3.3` direct-click records, marker revisions 1 through 7, all `valid=true`; guest publishes the complete binary grid with one `XPutImage`; nearest-rank p50/p95: input-to-presented 125.466/213.059 ms, input-to-display-receive 74.921/160.719 ms, Surface-to-selected-ready 27.265/34.235 ms, ready-to-selection 0.041/0.043 ms, selection-to-commit 0.367/0.437 ms, and commit-to-presented 22.715/22.854 ms. Eight further cold starts failed before arm with two commits and zero presented callbacks, so no interaction records were appended for them. | Exact marker-to-presented closure survives the atomic fixture, while the preceding 8 ms ready-to-selection tail disappears. Do not optimize production pacing from the older fixture tail. The seven-record sample and cold-start selection are insufficient for the paired gate; next collect same-session click/key/motion run clusters for both `v0.2.7` and current `v0.3.x`, while tracking zero-presented cold starts separately. |
| AIP-00 | 2026-08-30 | AIP-00d same-Session multi-action run | `/home/beribeli/swiftspice-aip00b/perf-ab/logs/20260830T021418Z.037hAL`; successful cluster `0000000000000008` emitted exactly three schema-2 `v0.3.3` records in click/key/motion order, all `valid=true`, from one process and Session. Input-to-presented was 197.254/107.894/216.268 ms; input-to-display-receive 139.868/71.023/162.285 ms; ready-to-selection 0.010/8.195/0.012 ms; commit-to-presented 22.045/24.927/22.124 ms. Motion used absolute tablet `mousePosition`, so `motion_ack_ns` is correctly absent while guest-received, marker-drawn, and exact-presented evidence is complete. The retained run also includes fail-closed development clusters that exposed markerless retry pollution, a zero-presented pre-arm cold start, and the invalid absolute-motion ACK assumption. | Closes the current-version click/key/motion smoke gate and proves serialized exact-presentation plus remote-append ordering. It remains directional direct-Session evidence, not AppKit receipt or the ten-cluster paired `v0.2.7`/current acceptance artifact; AIP-00 and AIP-44 stay open. |
| AIP-00 | 2026-08-30 | AIP-00e paired artifact acceptance / `a31ae5b`, `34f754d` | Strict Debug focused gate passed 11 tests / 26 parameterized cases. It accepts only 60 valid records from ten canonical clusters, two exact versions, and 20 unique counterbalanced runs; verifies plan-derived pair/token/checksum/order and pointer-mode ACK identity; rejects missing, duplicate, reordered, aliased, extra, invalid, non-finite, and timestamp-underflow inputs; handles display receive before send-continuation completion with a zero-clamped interval; and computes Hyndman-Fan type-7 per-version quantiles plus same-cluster signed paired deltas. The unchanged `v0.2.7` tag `2c577d7` also completed a Release build under the current Swift 6.3/Xcode-beta toolchain before any overlay was applied. | Establishes a deterministic admission and reporting gate without making a latency claim. CPU/RSS samples require exact run coverage but are independent guardrails. The isolated `v0.2.7` measurement-only overlay and live 10-cluster paired collection remain required; no AIP-44 pacing change is admitted. |
| AIP-10 | 2026-08-26 | PR #20 / `f68f6c6` | Apple Silicon SwiftPM CI; `swift build -Xswiftc -warnings-as-errors`; `InboundMessageBatchTests` 9/9 with 14 malformed-list arguments; `ChannelConnectionBatchTests` 3/3; `git diff --check` | Full-header batches share one owned body, dispatch submessages before the main prefix, and count ACK once per physical message. PR CI passed. Live-peer coverage remains for AIP-90. |
| AIP-11 | 2026-08-26 | PR #21 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; `ProcessedSerialBarrierTests` 16/16; combined serial-barrier tests 19/19; `ChannelMigrationTests` 5/5; AIP-10 batch regression 12/12; `SpiceSessionTests` 61/61; `DisplayChannelTests` 50/50; `git diff --check` | Effective full and implicit-mini serials advance after the physical batch handler and ACK succeed. A SET_ACK main or submessage excludes its complete physical batch from the new ACK window. A MIGRATE message may emit its triggered protocol ACK after entering migration state without opening ordinary client sends. Handler/transport failure, cancellation, and close terminate only dependent unsatisfied waiters, and a terminal connection rejects later client sends. Superseded receive tasks cannot poison a replacement connection or its shared barrier; an already-started Agent byte stream drains on its captured retiring connection before that transport closes, without delaying later target sends. Disconnect cancels that retirement wait, closes both retained source and target state, and cannot publish a late migration completion. `migrationRequested` remains recoverable. |
| AIP-12 | 2026-08-27 | PR #22 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; `DisplayImageCacheTests` 17/17; `DisplayChannelTests` 65/65 (one test executes 4 release cases); `SpiceSessionTests` 62/62; combined focused gate 144/144; message-framer/inbound-batch 12/12; connection-batch 3/3; 1,000-iteration immediate-promotion stress; `git diff --check` | One Session-owned actor coordinates every Display image reference. Each noncopyable mutation begins before asynchronous decode, stages its bitmap afterward, and uses consuming commit/abort so cache publication remains behind successful Surface work. Same-ID mutations run through a bounded FIFO instead of being rejected; cancellation, clear, and close release continuations and budgets exactly once. Cross-Display resolves remain bounded to 64 waiters and one cache-sized retained-byte budget. Active/queued mutation counts and retained/staged bytes have hard limits. A logical submessage accounts the complete physical batch storage retained by its `Data` slice, closing the gap between the wire-size limit and the cache budget. Targeted and global invalidation mark all active and queued work registered at their linearization point, preventing decode-time resurrection without retaining unknown-ID tombstones. AIP-11 barriers order `INVAL_ALL_PIXMAPS`; seamless rebinding retains the source cache, while replacement and teardown close exactly their owned cache. No performance claim is made before AIP-00. |
| AIP-20 | 2026-08-27 | PR #23 | `swift build -Xswiftc -warnings-as-errors`; `PixelRegionTests` 5/5 with 500 fixed-seed differential cases; pathological 4,096-clip and 65,536-segment limits; `DisplayChannelTests` 68/68; `SurfaceStoreTests` 37/37; combined focused gate 110/110; `git diff --check` | Display destinations, stream clips, and stream frames normalize `destination ∩ surfaceBounds ∩ union(clips)` before mutation. Nil and single clips use inline storage; multi-clip input uses coordinate compression, a y sweep, and lazy range-add coverage counts to emit canonical bands. Same-Surface clipped copies traverse bands and intervals opposite the translation direction so canonical sorting cannot overwrite a later segment's source. The implementation follows spice-gtk/spice-common pixman region semantics while adding deterministic Swift input/output limits. One-command Surface transactions and the per-row O(1)-space COPY_BITS kernel remain scoped to AIP-21 and AIP-22. No performance claim is made before AIP-00. |
| AIP-21 | 2026-08-27 | PR #24 | `swift build -Xswiftc -warnings-as-errors`; three parameterized transaction tests / 13 wire cases; `DisplayChannelTests` 71/71; `SurfaceStoreTests` 37/37; `PixelRegionTests` 5/5; combined focused gate 113/113; `git diff --check` | Pre-fix acceptance produced 29 issues: five multi-segment commands advanced two revisions without a transaction count, and three later-invalid source cases partially modified their destination. Region-level fill, COPY_BITS, bitmap DRAW_COPY, and same/cross-Surface DRAW_COPY now validate all segments before one backing preparation and one commit. Non-empty commands increment revision, mutation generation, and `mutationTransactions` exactly once; empty and failed commands leave pixels, descriptors, damage, copy/materialization metrics, and source surfaces unchanged. AIP-20 directional traversal remains intact. Per-row O(1)-space COPY_BITS and bulk kernels remain AIP-22 scope. No performance claim is made before AIP-00. |
| AIP-22 | 2026-08-27 | PR #25 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; six parameterized tests / 33 cases; `SurfaceStoreTests` 43/43; AddressSanitizer `SurfaceStoreTests` 43/43; `DisplayChannelTests` 71/71; `git diff --check` | The pre-fix direction oracle passed 19 single/multi-segment cases, confirming correct pixels but not allocation behavior; the four planned metrics were absent. Same/cross-Surface copies now use bounded unsafe-buffer lifetimes with direct `memmove`/`memcpy`, no area staging, and `temporaryCopyBytes == 0`. Same-Surface overlap is always per-row and bottom-up when moving downward; only non-overlapping contiguous rectangles use one bulk call. An independent post-fix test pass caught and closed the initial overlap/bulk classification gap. Fill uses one arm64 NEON kernel call per canonical segment while preserving ARGB/xRGB alpha rules. AIP-21 validation and one-command transactions remain intact. No throughput claim is made before AIP-00. |
| AIP-23 | 2026-08-27 | PR #26 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; six focused tests / nine parameter cases; `SurfaceStoreTests` 46/46; AddressSanitizer `SurfaceStoreTests` 46/46; `SurfacePublicationDamageTests` 3/3; `DisplayChannelTests` 71/71; `git diff --check` | The pre-fix focused gate produced 24 issues: full-raw followed by fill, same-Surface COPY_BITS, partial bitmap DRAW_COPY, or a held lease materialized the complete Surface on the CPU and uploaded damage again at the next snapshot. Eligible CPU kernels now continue from the IOSurface-canonical revision in place when unleased or through a synchronized immutable candidate while a lease is held. The actor rechecks lifecycle, revision, and canonical identity after synchronization; unsafe pointers remain within synchronous IOSurface-lock closures. Dual-canonical cross-Surface copy stays direct. Pool exhaustion falls back atomically to Data. Internal catch-up damage is reset at the direct commit, publication damage is retained until one matching snapshot consumes it, and the public API is unchanged. No throughput claim is made before AIP-00. |
| AIP-30 | 2026-08-27 | PR #27 | `swift test --disable-sandbox -Xswiftc -warnings-as-errors`; `MessageFramerTests` 14 declarations / 19 parameter executions; `ByteReaderTests` 8/8; `InboundMessageBatchTests` 10 declarations / 23 executions; `SpiceWireTests` 36 declarations / about 54 executions; `SpiceProtocolTests` 46/46; `ChannelConnectionBatchTests` 3/3; `DisplayChannelTests` 71 declarations / 84 executions; AddressSanitizer wire and channel-batch gates; Release strict build; generated-source and Public API checks; `git diff --check` | Pre-fix, malformed `nextBatch` consumed its 43-byte physical boundary before validation and advanced to the next message. Independent testing then caught a segment-boundary out-of-bounds trap and up to 1,023 logically consumed owners retained behind the head index. Latest-head review caught a further owner-amplification path where tiny reads stayed under the byte budget while creating unbounded segment metadata; the framer now rejects a 4,097th live receive segment before owner allocation with `.tooManySegments`, and consumed/reset slots immediately restore capacity. The bounded segment queue retains a contiguous body as one owner/range with `bodyCopyBytes == 0`, coalesces a fragmented body exactly once, never compacts received bytes, and validates a batch before cursor advancement. A malformed fragmented retry reports its one cached coalesced owner without copying again; that cache is byte-bounded but does not consume receive-segment capacity. Production channels and protocol readers accept `WireSlice`; Swift 6 `Span` remains synchronous and non-escaping, while Data is materialized only at established event or codec boundaries. Full-header retained-byte accounting includes the actual input owner. No throughput claim is made before AIP-00. |
| AIP-31 | 2026-08-27 | PR #28 / `6488491` | `swift test --disable-sandbox --no-parallel -Xswiftc -warnings-as-errors`; focused LZ/GLZ gate 24/24; eight AIP-31 declarations / 27 parameter executions in Debug, Release, and AddressSanitizer; `SpiceCodecsTests` 43/43; full AddressSanitizer suite; Release strict build; generated-source and Public API checks; Apple Silicon SwiftPM CI including coverage; `git diff --check` | The previous RGB path allocated `[UInt8]` and then converted it to `Data`; the palette path additionally retained a packed-byte array and rejected an exact final-output byte limit because it budgeted packed plus BGRA storage. All formats now write one preallocated BGRA `Data`. Color and packed references copy one initialized period and double it; alpha references use one strided overlap-kernel call. Palette decoding uses the same backing prefix for packed bytes, then expands rows backwards through a maximum 8 KiB byte-to-BGRA table, preserving partial row tails, cross-row references, 4-bit modulo, and 8-bit rejection. Immutable per-decode diagnostics report one decoded allocation, zero temporary decoded backings, bounded reference calls, and exact lookup pixels. Malformed attempts remain deterministic and publish no result. Review of the implementation commit reported no major issue. No throughput claim is made before AIP-00. |
| AIP-32 | 2026-08-27 | PR #29 / `36e3805` | Apple Silicon SwiftPM CI run `33069734096`, job `98508596839`: build, generated protocol, C-shim analysis, public API, full tests, AddressSanitizer, and coverage passed; full local Debug warnings-as-errors and AddressSanitizer gates; focused Release and ThreadSanitizer `DisplayChannelTests` 75/75 and `GLZDecoderTests` 25/25; `git diff --check`; four P1 findings fixed in paired source/test commits | One Session-owned FIFO GCD-backed Swift `TaskExecutor` runs stateless JPEG/LZ/QUIC/palette/ZLIB and independent GLZ CPU work at width two, with 64 pending jobs and 256 MiB queued-retention limits; MJPEG remains per-stream serial. GLZ parses at most 1,048,576 operations, waits for immutable dependency snapshots outside worker permits, reserves image IDs, rejects stale clear generations, commits out of order while advancing one deterministic contiguous eviction tail, and checks cancellation inside large copies. Review found and closed four amplification/complexity gaps: wait and executor budgets include parsed programs and dependency snapshots; short-distance overlap uses bounded prefix doubling while the long-distance phase fixture stays bit-exact; Display stateless-codec admission charges the full physical owner; and direct GLZ plus the second ZLIB_GLZ phase add that owner exactly once to internal wait/executor accounting with checked overflow, exact-boundary, cancellation, and zero-accounting tests. Swift 6.3 typed-continuation and `withUnsafeBytes` compatibility is covered by CI. No throughput claim is made before AIP-00. |
| AIP-33 | 2026-08-27 | PR #30 / `58b6664` | Apple Silicon SwiftPM CI run `33074368881`, job `98524596495`: build, generated protocol, C-shim analysis, public API, full tests, AddressSanitizer, and coverage passed; full local Debug warnings-as-errors and AddressSanitizer gates; focused Debug, Release, and ThreadSanitizer gates 21/21 (`AdvancedVideoDecoderTests` 8 declarations / 9 cases, `VideoToolboxDecoderTests` 6 declarations / 8 cases, `AdvancedVideoCorpusTests` 7/7); strict Debug and Release builds; `git diff --check`; exact-head Codex Review found no major issues and the inline-comment and review-thread audits were empty | Annex-B parsing now performs one bounded scan into checked ranges sharing one immutable payload owner, with zero eager input or NAL payload copies. Parameter-only input allocates no AVCC sample; encoded input uses one exact AVCC allocation, and unchanged parameter sets compare without rematerialization. VideoToolbox lends CoreMedia a stable retained `NSData` owner through `CMBlockBufferCustomBlockSource`, eliminates the explicit `CMBlockBufferReplaceDataBytes` payload copy, and balances retain/release exactly once on success, synchronous block/sample creation failure, decode-submission failure, real task cancellation, teardown, and close. Package-only deterministic seams and immutable diagnostics verify bit-exact bytes, copy counts, retry atomicity, owner activity, and release behavior without changing the public API. No throughput claim is made before AIP-00. |
| AIP-40 | 2026-08-27 | PR #31 / `2a8dd26` | Apple Silicon SwiftPM CI run `33078422258`, job `98538713848`: build, generated protocol, C-shim analysis, public API, full tests, AddressSanitizer, and coverage passed in 8m48s; full local Debug warnings-as-errors and AddressSanitizer gates; strict Debug and Release builds; complete `SpiceSessionTests` 68/68; focused Debug, Release, and ThreadSanitizer gates 6 declarations / 9 executions; strengthened six-child late-success rollback passed in Debug, Release, and ThreadSanitizer; `git diff --check`; exact-head Codex Review found no major issues and the issue-comment, inline-comment, and review-thread audits were empty | Initial bootstrap and migration-target preparation now share one manual-width-four `TaskGroup<Result>` connector. It validates the entire descriptor inventory before transport creation, creates transports in descriptor order, and restores successful results to descriptor order before ownership transfer. A first failure or cancellation stops admission, cancels remaining tasks, drains the whole group, and closes early and late successes before returning; `ChannelFactory` closes handshake failures and pre-start cancellation closes its precreated transport. Tests cover exact widths four and five, out-of-order completion, duplicate prevalidation, six-child early/active/late/not-started ownership, direct task cancellation, disconnect, migration success/failure/cancellation, and preservation of the source Session. No throughput claim is made before AIP-00. |
| AIP-41 | 2026-08-29 | PR #43 / `7e75d27` | Apple Silicon SwiftPM CI run `33227372335`, job `99033594956`: build, generated protocol, C-shim analysis, public diagnostics API, full tests, AddressSanitizer, and coverage passed in 9m46s; local full strict and AddressSanitizer suites 659/659; focused Debug, Release, and ThreadSanitizer `DisplayFramePublisherTests` 27/27; PublicAPIConsumer warnings-as-errors build; `git diff --check`; exact-head Codex Review found no major issues; all four P1 threads were fixed, replied to with commit/test evidence, and resolved | Each flush retains at most 16 requests and runs at most two structured snapshot children while preserving stable Surface emit order. Cancellation directly stops and drains the manager, and production SurfaceStore FIFO reservations handle cancellation-before-registration, queued cancellation, grant races, and holder release during actor reentrancy without orphaning a lease or consuming damage. Non-empty publication damage remains under an exactly-once commit/restore lease: ordered emit commits it; cancellation or stale rejection restores and merges it with later same-lifecycle damage. Deterministic real-store tests cover blocked independent progress, bounded refill, direct cancellation, every reservation race, and two prepared Surfaces canceled behind a suspended emit, including partial-damage preservation across a replacement publisher. No throughput or input-latency claim is made before AIP-00. |
| AIP-42 | 2026-08-29 | PR #47 / `2226f50` | Apple Silicon SwiftPM CI run `33247879206`, job `99088398311`: build, generated protocol, C-shim analysis, public API, full tests, AddressSanitizer, and coverage passed in 13m15s; focused ring/capture/playback/record gate 38 tests / 4 suites in Debug, Release, ThreadSanitizer, and AddressSanitizer; local full warnings-as-errors suite; PublicAPIConsumer warnings-as-errors build; `git diff --check`; exact implementation-head Codex review found no major issues; successor PR audit retained all ten resolved Draft #34 review threads | Playback and capture use fixed-capacity preallocated PCM rings with checked 16 MiB queue and 262,144-slot limits; playback exposes one additional 16 MiB staging bank and commits ordinary metadata or overflow bank swaps under the short render gate. Capture reuses bounded conversion buffers, supports oversized interleaved and planar callbacks, defers failure formatting, and materializes `Data` only through an entry-snapshot-bounded two-phase async drain. Package diagnostics and tests prove zero callback-owned logical allocations, per-packet storage allocations, and linear movement in the affected paths. Public API is unchanged. This deterministic completion makes no audio performance claim; real audio-device behavior remains an AIP-90 gate. |
| AIP-43 | 2026-08-29 | PR #48 / `7e405f1` | Apple Silicon SwiftPM CI run `33251870601`, job `99098817923`: build, generated protocol, C-shim analysis, public API, full tests, AddressSanitizer, and coverage passed in 11m45s; focused WebDAV Debug and Release gates 20/20; related WebDAV, Session, executor, wire, and channel filter 33 executions under ThreadSanitizer and AddressSanitizer; `git diff --check`; exact implementation-head Codex review found no major issues; all three successor P1 threads were fixed, replied to with source/test evidence, and resolved, and all four retained Draft #35 constraints were rechecked | One width-two GCD-backed Swift `TaskExecutor` admits at most 64 filesystem jobs and 256 MiB of server-retained request/response storage. Per-client filesystem work and complete response sends remain serial while unrelated clients overlap; failed sends, close, cancellation, Session identity changes, and same-ID filesystem or sender retirement suppress stale generations with exactly-once accounting. `HEAD` is metadata-only with exact length, and depth-one `PROPFIND` lazily stops at the response limit with at most 4,096 retained child fragments. The public synchronous API is unchanged. This deterministic completion makes no throughput or live-interoperability claim; live WebDAV behavior remains an AIP-90 gate. |

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
| 2026-08-27 | AIP-32 | Share one GCD-backed Swift `TaskExecutor` of width two per Session, cap FIFO admission at 64 pending jobs and 256 MiB of retained input, and keep GLZ dependency waits outside worker permits | Current spice-gtk master `88ad5f1` owns one GLZ window per Session, explicitly accepts out-of-order image arrival across display sockets, and separates window coordination from per-surface decoders; its GLZ template also records a TODO to split distance/length parsing from copying. Swift 6 task-executor preference moves blocking codec work off the default cooperative pool instead of merely counting it with an actor semaphore. Swift parses a bounded GLZ program, resolves immutable dictionary snapshots in the actor, then acquires Session admission only for cancellation-aware CPU decode. The actor reserves image IDs, commits out-of-order completions with existing contiguous-tail eviction semantics, and rejects commits from an older clear generation. Stateless JPEG/LZ/QUIC and ZLIB work share the executor; stateful MJPEG keeps its per-stream serial executor and existing width-two limiter. FIFO admission, cancellation removal, conservative parsed-program/dependency and complete physical-wire-owner accounting, checked retention arithmetic, prefix-doubling overlap copies, and immutable diagnostics make overload deterministic without occupying worker slots while waiting on dictionary order. All four P1 review findings are resolved and promoted these accounting and copy-complexity constraints to durable requirements. |
| 2026-08-27 | AIP-33 | Represent Annex-B NAL units as checked ranges into one immutable payload owner, allocate AVCC exactly once, and lend CoreMedia a stable retained owner through a custom block source | The prior path copied the full Annex-B payload into an array, materialized each NAL, grew AVCC through appends, and then copied AVCC again with `CMBlockBufferReplaceDataBytes`. Swift 6 requires unsafe byte access to remain synchronous and scoped, so range metadata crosses isolation while raw pointers do not. A retained `NSData` provides stable storage for CoreMedia; its `refCon` and once-only free callback make ownership explicit and testable across synchronous creation failure, decode-submission failure, cancellation, teardown, and close. Package-only diagnostics and failure seams preserve the public API while making scan count, allocations, copies, parameter-set materialization, and owner balance deterministic acceptance criteria. |
| 2026-08-27 | AIP-40 | Keep SPICE's independent per-channel links, but prepare child channels through one deterministic Swift task group with manual width four and explicit ownership transfer | spice-gtk's channel model keeps each advertised child on its own link; connecting those independent links serially is not a protocol-ordering requirement. Swift 6 structured concurrency can overlap the network and handshake latency, but a throwing group alone does not prove that already completed or late successful connections remain observable after a sibling fails. A nonthrowing `TaskGroup<Result>` therefore admits at most four descriptor-ordered transports, stops admission on first failure/cancellation, drains every result, closes all successes before propagating failure, and transfers ownership only after complete success. Initial bootstrap and migration preparation share this helper so cancellation and rollback cannot drift. |
| 2026-08-28 | AIP-00, AIP-44 | Prioritize perceived interaction latency, decompose it before optimization, then evaluate clarity; keep CPU and RSS as guardrails | The adjacent Maspice observation improved snapshot and selection-request-to-presented time while ready-to-selection p95 regressed sharply. Because the reported diagnostic interval contained no correlated input event, the observation cannot identify input scheduling as a cause. Immediate or adaptive frame selection therefore requires same-action input/revision tokens, first-ready and selected-ready timestamps, tick-phase and drawable-capacity evidence, and must retain latest-only, idle no-commit, and bounded GPU in-flight invariants. |
| 2026-08-28 | AIP-00, AIP-44 | Land revision-accurate selected-ready diagnostics before any AIP-44 scheduling change | A pacing experiment is interpretable only after coalesced revisions carry their own ready timestamp and unsolicited exact duplicate identities cannot move or re-wake that timestamp. Explicit authoritative `requestLatest()` redraws receive a fresh delivery identity even when frame revision and generation are unchanged, preserving retry and resize behavior; live paired external artifacts remain the completion gate. |
| 2026-08-28 | AIP-00 | Use the Rocky 9 rootless Podman/KVM fixture first for real connectivity and receive-to-present baselines; do not treat its autonomous animation as paired interaction evidence | The current animation has no causal input token. Before the fixture can admit click/key/motion-to-visible observations, the guest must emit a unique rendered marker and the harness must retain a per-event trace that correlates that marker through the matching presented revision. Until then, the fixture can validate transport and the receive-to-surface-ready-to-selection-to-Metal-commit-to-presented pipeline only. |
| 2026-08-28 | AIP-00, AIP-44 | Land a unique guest input-marker state machine and normalized per-event trace schema before scheduling experiments | The fixture can now pre-arm one click/key/motion token, consume it only on a matching real guest input, draw a deterministic high-contrast ROI, and record guest marker evidence. Autonomous animation remains ineligible. This slice does not yet bind captured marker pixels to an exact AppKit presented delivery; that live Rocky correlation remains mandatory before any paired latency artifact or AIP-44 scheduling claim. |
| 2026-08-29 | AIP-00, AIP-44 | Treat the successful Rocky eudev/Xorg marker run as guest-causal subpath evidence, not an input-to-visible result | Key, motion, and click now reach the guest marker and relative motion produces protocol ACKs, but no collector yet binds those marker pixels to an exact SwiftSpice delivery and AppKit presented callback. Complete that binding and paired `v0.2.7`/`v0.3.x` traces before selecting an immediate or adaptive ready-to-selection policy. |
| 2026-08-29 | AIP-00 | Land the exact host identity and presented-callback correlation seam before changing the Rocky pixel protocol or collector | Keeping source timing beside the exact emitted Display revision prevents coalesced replacements from inheriting neighboring evidence. The internal BGRA detector and assembler now fail closed across marker, generation, selection, commit, and presented identity, while the separate fixture slice remains responsible for a shared versioned ROI and normalized JSONL artifacts. No pacing behavior or performance conclusion changes in this slice. |
| 2026-08-29 | AIP-00 | Share `binary-grid-v1` between the guest and Swift, normalize schema 2 through a bounded atomic collector, and reserve a separately named Rocky endpoint for the live gate | The local implementation can retain exact valid and attributable-invalid evidence without partial JSON lines, but it is not live completion evidence. The next run must use an isolated base/container/ports, verify the manifest capability, and bind real marker pixels to the same presented delivery before paired latency work or any AIP-44 scheduling decision. |
| 2026-08-29 | AIP-00 | Make fixture identity overrides all-or-none and split host send-start from send-completion evidence | A partial later-shell environment must fail before filesystem or Podman effects rather than target the default endpoint. Recording the host-input/send-start boundary before the wire send allows a frame received before the send continuation resumes to remain causally eligible; send completion and a same-generation buffered motion ACK are linearized afterward without changing scheduling. |
| 2026-08-29 | AIP-00 | Add a streaming guest trace boundary and a cancellation-safe exact-presentation wait before an env-gated live AppKit harness | The guest transaction exposes ARMED before input and accepts one ordered action/token/revision pair under one total budget. The package wait wakes only for the selected, committed identity accepted by AppKit presented; neither seam finishes a trace, changes pacing, or turns the isolated guest-causal smoke run into presented evidence. |
| 2026-08-29 | AIP-00, AIP-42 | Record the foreground live gate as blocked and resume deterministic AIP-42 work on `main` without making a performance claim | The isolated Rocky endpoint is available, but the current Mac WindowServer session remains occluded and cannot establish visible demand. Preallocated audio ownership, FIFO, overflow, cancellation, allocation-counter, and sanitizer gates are deterministic and independent of that display environment. The earlier reviewed Draft PR #34 is retained only as design/review evidence because its stacked base was not integrated; a clean successor carries the current implementation. AIP-42 may be marked done when its deterministic completion gate and current-head review pass, while live audio-device behavior remains part of AIP-90. |
| 2026-08-29 | AIP-00, AIP-43 | Resume deterministic AIP-43 work on current `main` and remove its AIP-00 dependency without making a performance or interoperability claim | Bounded admission, retention accounting, per-client ordering, cross-client progress, generation invalidation, and same-ID retirement are deterministic and independent of the occluded WindowServer gate. The earlier reviewed Draft PR #35 is retained as design and review evidence because its stacked base was not integrated; a clean successor will preserve all four resolved review constraints. Live WebDAV interoperability remains an AIP-90 gate. |
| 2026-08-29 | AIP-43 | Close the deterministic executor item only after the successor also bounds metadata-only HEAD, lazy depth-one PROPFIND, and response-sender retirement | Exact-head review found three additional retention/lifecycle gaps beyond the four retained Draft #35 findings. Metadata-only HEAD prevents a 4 KiB response reservation from hiding a full-body load; lazy PROPFIND plus a 4,096-child cap bounds sorting metadata; and same-ID reuse waits for both synchronous filesystem work and suspended response delivery. Paired source/test commits, sanitizers, and Apple CI close those deterministic gates without replacing AIP-90 live interoperability. |
| 2026-08-30 | AIP-00, AIP-44 | Resume AIP-00 after the unlocked exact-presentation gate, but defer an AIP-44 pacing change until paired atomic-marker traces exist | Ten valid per-cell-marker and seven valid atomic-marker direct-click traces bind one guest token through the exact presented identity. The atomic fixture removes the preceding 8.044 ms ready-to-selection tail (p95/max 0.043 ms) without improving the larger input-to-display tail, showing that the fixture itself can create the apparent scheduling wait. Eight zero-presented cold starts also require a separate harness/reliability guardrail. Neither result covers AppKit receipt, key/motion, paired versions, or required run clusters. |
| 2026-08-30 | AIP-00 | Serialize one deterministic click/key/motion cluster before paired collection, and keep ACK semantics pointer-mode-aware | A single Session now proves action order, exact presented identity, and per-step remote append. Markerless redraw/drop/failure traffic may rebind only its own non-target stage; an expected-marker duplicate remains fail-closed. Relative `mouseMotion` requires a clean-epoch ACK, but absolute tablet `mousePosition` does not produce that protocol ACK and is instead closed by guest and exact-presented evidence. The successful current-version cluster is a smoke gate only; ten paired clusters and AppKit receipt correlation remain pending. |
| 2026-08-30 | AIP-00 | Reject incomplete paired artifacts before computing statistics, and instrument `v0.2.7` only through an isolated measurement overlay | Comparing independent version quantiles can hide cluster-level regressions, while filtering invalid or cold-start rows can bias the accepted population. The evaluator therefore requires the exact counterbalanced 10×2×3 matrix and reports same-cluster/action signed deltas. Because later publisher, Surface, Session, and Metal algorithms cannot be disabled faithfully, the baseline will use a separate `2c577d7` worktree with a reviewable measurement-only patch queue; it must not import concurrent snapshot preparation, ready-latch/pacing changes, drawable retry/redraw recovery, or other `v0.3.x` algorithms. |
