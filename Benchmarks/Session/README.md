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
