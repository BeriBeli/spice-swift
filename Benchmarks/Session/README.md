# Real-session performance tool

`spice-session-benchmark` connects to an explicitly selected live SPICE endpoint.
It has no dependency on the opt-in microbenchmark framework and does not provision
VMs, run SSH commands, or change the guest's display configuration.

## Observe an existing workload

From the repository root:

```sh
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift run --skip-build spice-session-benchmark connection.vv \
  --observe-seconds 30 --label wifi-before > .build/session-before.json
```

Alternatively pass `HOST PORT`; the ticket is read from `SPICE_PASSWORD`. The
same environment variable overrides a ticket supplied by `.vv`. Connection files
support direct TCP/TLS, escaped PEM `ca=`, and the complete `host-subject=` via
the library's virt-viewer trust policy. When both ports exist, TLS is used for
every channel. `tls-ciphers=DEFAULT` selects the system TLS defaults; an OpenSSL
cipher ordering is not reproduced. Certificate failure never triggers TCP
fallback. Proxy routes (including `pvespiceproxy:`), custom cipher overrides and
public-key pinning are rejected; the transport does not implement those
connection-file features. The source file is preserved even with
`delete-this-file=1`.

The tool opens the production `SpiceFramebufferView` and Metal presenter. Keep
this window visible and unobstructed. Host physical input is not forwarded;
prepare the guest workload before connecting, or control it separately.
`--headless` observes publication without a window and therefore cannot measure
drawable presentation. Choose exactly one of `--enable-h264` and `--enable-h265`
to opt into advanced video; otherwise the `.mjpegOnly` policy applies. The report
includes actual MJPEG, native-video, hardware/software decoder and fallback
counters, so an advertised codec policy is not mistaken for the observed path.
`presentationStatus` separates headless observation, confirmed Metal presentation,
CPU fallback and absence of confirmed presentation. A completed observation
window alone does not establish successful drawable presentation; fallback
categories and counts remain visible in the report.

## Measure input to the corresponding presented frame

1. Copy `guest-marker.html` and `marker-grid.js` together to a guest with a modern
   browser using a file-transfer path available in your environment. Open the
   HTML file there, or serve that directory with the guest's static HTTP server.
   Host and guest may be on different networks; loading these files locally in
   the guest requires no guest-to-Mac HTTP connection or telemetry server.
2. Enter a 16-digit hexadecimal base token (for example `1234567800000000`),
   click **Arm and enter fullscreen**, and keep that guest browser focused at
   100% zoom. If fullscreen permission fails, use the browser's fullscreen key.
   The marker must lie at physical desktop coordinates `(16, 16)` on primary
   surface/channel zero. Close other SPICE clients before starting the tool.
3. Run the host tool with the same token:

```sh
swift run --skip-build spice-session-benchmark connection.vv \
  --marker-base 1234567800000000 --warmup 5 --samples 50 \
  --interval-ms 100 --trace .build/interaction-before.jsonl \
  --label wifi-before > .build/interaction-before.json
```

The initial zero-revision marker is required before input is sent. Each synthetic
Space keydown advances a unique token and guest revision; a keyup immediately
follows. The next input waits for that exact delivery's Metal presented callback.
Warmup events appear in JSONL as orders `1...warmup`, but are excluded from the
report's interaction percentiles and measured resource window. Reload and re-arm
the guest page before every run, including after failure. Reuse the same base
token for comparisons only after resetting the page.

`--ready-timeout-seconds` defaults to 60; `--timeout-seconds` defaults to 10 for
connection and each complete input/presentation transaction. Samples are limited
to 1,000 and warmup to 100. A missing marker, lost connection, send failure,
invalid causal record or timeout fails the run with nonzero exit status. The
failed sample is retained in JSONL when capture has started. A failed run still
emits a JSON summary, including partial accepted samples. Ctrl-C, SIGTERM and
window close cancel the run and tear down its subscription, view and session.

JSON goes to stdout; progress and fixed failure categories go to stderr. Capture
uses the existing bounded, owner-only, atomic JSONL writer (16 MiB total limit).
Choose an output directory that already exists. Existing compatible JSONL is
appended; each run has a unique `runID`/`runId`. Reports contain no endpoint, ticket,
certificate, clipboard data, screenshot or encoded display payload. Keep the
user-supplied label free of secrets.

## Interpret and compare results

Interaction stages use exact nearest-rank P50/P95 over **valid measured records**:

| Field | Boundary |
| --- | --- |
| `schedule_to_input` | Synthetic scheduling to creation of this tool's input |
| `input_to_send` | Synthetic input creation to calling `SpiceSession.send` |
| `send_call` | Local keydown send invocation to continuation resumption |
| `send_start_to_display_receive` | Send invocation to a complete framed display message carrying the marker |
| `send_complete_to_display_receive` | Send completion to display receive, only when these do not overlap |
| `display_receive_to_surface_ready` | Decode and canonical Surface apply |
| `surface_ready_to_selection` | Publication, desktop delivery and display scheduling |
| `selection_to_commit` | View selection to Metal command commit |
| `commit_to_presented` | Metal commit to calibrated drawable presented time |
| `input_to_presented` | Synthetic input creation to that same marker delivery's presentation |
| `guest_handler_to_marker_draw` | Guest event handler entry to issuing marker drawing |

Local send completion is not remote receipt. The send-to-display interval
combines transport, server, guest handling and return transport; it does not
separate network RTT. Display receive starts after complete message framing.
The synthetic path does not measure NSEvent delivery or the bundled viewer's
input FIFO. Drawable presented time is system presentation evidence, not a
physical monitor sensor measurement.

The guest draws the original two-row binary-grid marker plus an optional second
grid one cell below it. The second grid contains magic `0xA5C4`, guest receive
nanoseconds, guest draw-issue nanoseconds, and the same per-token checksum. These
timestamps use only the guest's `performance.now()` clock; they are never
subtracted from host timestamps. Draw-issue time precedes marker encoding and
canvas submission; it is not browser compositor completion. The marker ROI read
and browser fixture add overhead, so this is a controlled interaction workload,
not a claim about arbitrary terminal typing.

`diagnosticsSinceConnect` contains cumulative counters and bounded approximate
P95 histograms, including connection/readiness/warmup. Its gauges are best-effort
snapshots; IOSurface allocation is process-wide. `measuredSeconds`, CPU time,
desktop delivery FPS and interaction percentiles use the measured window. CPU
time includes the tool, ROI detection and trace persistence. Resident-byte
fields are process-lifetime high-water marks sampled before/after measurement,
not instantaneous RSS or a window-local peak. FPS counts distinct revisions
delivered to the observer, not physical display refreshes. The latest-only source
may coalesce frames.

The presentation histograms split `view_to_commit` into `drawable_preparation`
(selection through texture/view preparation), `drawable_acquisition` (only the
synchronous `MTKView.currentDrawable` getter, including nil results), and
`drawable_to_commit` (encoding, callback setup and presentation scheduling).
`commit_call` measures synchronous commit submission, including the immediately
preceding commit-timestamp publication; it is separate
from the existing `commit_to_completion` GPU completion interval. These are
aggregate histograms, not timestamps attached to an individual marker. Their
percentiles and maxima must not be added or subtracted. A long `view_to_commit`
alone does not identify drawable acquisition as the cause.

For reproducible comparisons retain the commit/dirty state, Swift/Xcode version,
hardware, power conditions, guest resolution/scale, browser version, workload,
network path and codec flags alongside the output. `frameSizes`, local backing
scale and maximum refresh rate help detect configuration changes. Use the same
guest state, build configuration and sample settings before and after a change.
For timing comparisons use the same Release build on both sides:

```sh
swift build -c release --disable-sandbox -Xswiftc -warnings-as-errors
swift run -c release --skip-build spice-session-benchmark connection.vv --observe-seconds 30
```

No universal latency threshold or performance improvement is claimed.

## Controlled quality fixture and explicit pixel export

`guest-quality.html` uses the same marker encoder, a deterministic RGB pattern,
and a requested 30 FPS horizontal motion workload. Space increments the marker;
M toggles motion, F freezes at phase zero, and R resets the counter. Its animation
rate is a target, not a measured guest compositor rate. Transfer it together with
`marker-grid.js`, or inline that script into a self-contained copy before transfer.
The SPICE server decides whether these updates become a video stream. Require
nonzero actual decoder counters before comparing codec policies.

`guest-fullfield.html` is a self-contained detection fixture: a 160×90 changing
gradient scaled fullscreen, requesting 30 FPS for 5400 timer callbacks after a
click. This is nominally 180 seconds, not a measured frame cadence or strict
wall-clock limit. It helps trigger stable dirty rectangles on the non-GL QEMU
display path; it is not native 1080p/4K video or a pixel-quality reference. The
[actual-server comparison](../../docs/PERFORMANCE_MJPEG_AB_2026-11-14.md) records
MJPEG admission, fragment presentation and full-Surface copy limitations.

The [native visible-response supplement](../../docs/PERFORMANCE_NATIVE_VISIBLE_2026-11-15.md)
adds real keyboard/mouse latency and CRC-validated region consistency through a
shared ScreenCaptureKit observer. It records capture overhead and source cadence;
Cocoa's dynamic code-readability failure prevents a complete-frame FPS ranking.
Raw data and the separate evidence archive preserve that limitation.

The benchmark can transfer an explicitly selected fixture through VDAgent without
clipboard synchronization. This operation exits after transfer and does not open
or execute the file in the guest:

```sh
swift run --skip-build spice-session-benchmark connection.vv \
  --transfer-fixture fixture.html --timeout-seconds 30
```

Transfer failures report a fixed category, last phase, and sent-byte count,
excluding source paths and underlying error strings. A sending-phase timeout
does not prove guest completion or safe automatic retry. The
[visible-window follow-up](../../docs/PERFORMANCE_VISIBLE_2026-11-14.md) records
a 32,000-byte stall and successful smaller video fixtures separately.

Observation can explicitly export the latest published source pixels as a PNG:

```sh
swift run --skip-build spice-session-benchmark connection.vv --headless \
  --observe-seconds 10 --snapshot .build/source-reference.png
```

Only this opt-in export writes guest image data. It happens after the resource
window and diagnostic snapshot; its CPU readback is excluded from those metrics.
The PNG is a source-frame observation, not an onscreen screenshot or proof of a
fully applied dynamic frame. Use F and a settled static reference for pixel-error
measurements; successive drawing messages can expose different animation phases.
Marker measurements reject `--snapshot` to avoid contaminating interaction runs.

## Actual viewer input under shaped transport

`shape-connection.py` (Python 3.11+) is an opt-in, loopback-only TCP byte relay.
Open its printed temporary `connection_path` in the actual viewer, enable Session
Diagnostics, and send physical/AppKit keys through that viewer. This exercises
the viewer input FIFO rather than the benchmark's synthetic `session.send` path.

```sh
python3 Benchmarks/Session/shape-connection.py connection.vv \
  --profile latency --metrics .build/relay-metrics.json
```

| Profile | Added one-way delay | Jitter | Aggregate rate per direction |
| --- | ---: | ---: | ---: |
| baseline | 0 ms | 0 ms | Unlimited |
| latency | 50 ms | ±20 ms | 20 Mbit/s |
| bandwidth | 25 ms | ±10 ms | 2 Mbit/s |

All channels share a directional rate budget. Each connection/direction has at
most sixteen queued 16 KiB chunks, in addition to bounded stream/OS buffering.
Jitter applies to ordered TCP chunks; this does not simulate IP packet loss,
packet reordering, Wi-Fi behavior, or a precise measured network RTT. Profiles
change several conditions together and do not isolate a single network variable.

TLS remains end-to-end with the input file's CA and complete subject pin. The
relay changes only the address/port. Its sole credential-bearing copy has mode
0600 in a mode-0700 owned temporary directory and is removed on Ctrl-C/SIGTERM.
Keep the relay alive for the connection, close the viewer, then stop it. Do not
archive temporary `.vv` files. No system-wide networking settings are changed.
Relay connection-error counts cover its entire lifetime, including teardown.

Record guest counter correctness independently of the viewer's aggregate input
queue/send metrics. Local send completion does not establish remote receipt or
input-to-presented latency. The 2026-11-13 campaign used forty Space presses in
two sequential batches, each held for 100 ms, with screenshot verification after
each batch. The source, codec, GPU and input evidence is described in the
[follow-up measurements](../../docs/PERFORMANCE_FOLLOWUP_2026-11-13.md).
