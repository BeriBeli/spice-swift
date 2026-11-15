# Visible Maspice pipeline measurements, 2026-11-14

The later [actual-server MJPEG comparison](PERFORMANCE_MJPEG_AB_2026-11-14.md)
independently records server versions/hashes, real `off/all/filter` runs, a
no-playback MJPEG admission correction and the remaining fragment-presentation
gate. Statements about pending work below describe this earlier record's cutoff.
Its raw measurements and original archive remain unchanged.

The next investigation used an instrumented Release Maspice window on the same
Linux Lite peer. Both canvas motion and actual fullscreen HTML video playback
arrived as desktop drawing messages. No SPICE video stream was requested.
Subsequent user-reported server inspection identified two constraints: direct
QEMU startup leaves video detection at its default `off`, and the installed
SPICE library lacks GStreamer encoder support. The next comparison for this
environment is desktop drawing versus native MJPEG streaming. H.264 evaluation
requires a server encoder/build change before a client preference can be tested.

The historical 1,007.6 ms selection-to-commit outlier remains unreproduced and
unexplained. These observations do not establish that it was fixed or caused by
`currentDrawable`.

## Method and provenance

- Same host and guest as the [previous investigation](PERFORMANCE_FOLLOWUP_2026-11-13.md),
  guest desktop 1920×1080, local fixtures, exclusive user-authorized session.
- Used `linuxlite.vv` with its existing CA/full subject validation. No server
  configuration, resolution, refresh policy, or installed app was changed.
- Built Maspice with its documented editable SwiftSpice dependency workflow and
  `PACKAGE=0 CONFIG=release scripts/build-app.sh`. The exact release requirement
  and original `Package.resolved` were preserved. Local editable state remains
  available for review; publishing requires an upstream release and reviewed pin.
- The main Maspice window remained visible. One desktop subscription and one
  visible subscription were observed. No headless observer was attached during
  these measurements. Diagnostics were read through native accessibility.
- Counter differences use before/after snapshots from the same connection.
  Snapshots are best-effort across actors and periodically sampled. Display read
  bytes include protocol headers/read-ahead after authentication, excluding
  TLS/TCP overhead. Rates below are approximate workload-window rates, not
  measured wire throughput. UI timing values are rounded and session-cumulative.
- The marker received 40 separate Space presses with 100 ms holds, in batches of
  20. Screenshot checks confirmed counts 20 and 40. Tool timing and screenshots
  do not measure per-key input-to-present or input-to-photon latency.

The machine-readable [record](../Benchmarks/Session/RESULTS_VISIBLE_2026-11-14.json)
contains raw counter differences, endpoint timing summaries, and host intervals.

## Results

| Workload | Display bytes received | DRAW_COPY source requests | Extra canonical GPU copy | Video stream create/data |
| --- | ---: | --- | --- | --- |
| 40 marker presses | 100,060 | LZ family 507 | 1,011,916,800 B; 122 waits | 0 / 0 |
| Canvas motion, host interval 21.080 s | 276,723,485 | LZ family 12,328 | 0 B; 0 waits | 0 / 0 |
| 10 FPS MP4 loop, host interval 21.243 s | 98,241,296 | QUIC 15,583; LZ family 14,849 | 2,786,918,400 B; 336 waits | 0 / 0 |
| 30 FPS MP4 loop, observation interval 26.413 s | 286,093,657 | QUIC 27,268; LZ family 24,977 | 0 B; 0 waits | 0 / 0 |

The 10 FPS source is H.264, 320×180, two seconds; the 30 FPS source is H.264,
160×90, 15 frames/0.5 seconds. Both looped and were upscaled by the guest browser
to fullscreen. These are stream-detection workloads, not native 1080p/4K codec
performance or quality tests. Requested/source frame rates and the number of
presented partial desktop revisions do not establish output FPS. The attempted
Space pause in the first video run did not stop playback; the endpoint snapshot
is retained and the video was later stopped by navigating away.

All stream create/data, MJPEG decode, VideoToolbox decode/session, and advanced
video presentation counters were zero in both video runs. The 30 FPS run also
avoids relying solely on a low-frame-rate video trigger. At measurement time,
the server configuration was unknown; the zero counters alone did not identify
it. The subsequent server inspection below supplies the missing configuration
and capability evidence without changing these measured results.

Marker copy waits totaled approximately 140.60 ms, averaging 1.152 ms per
attempt. The 10 FPS video run totaled 390.25 ms, averaging 1.161 ms. These waits
include GPU queue/completion and actor resumption, rather than pure GPU execution.
Zero extra canonical copies in the other windows does not mean zero memory
traffic: decode, CPU Data operations, uploads, and presentation work are outside
this counter. Total CPU copy cost was not measured.

At the marker endpoint, local send p95/max was 0.5/0.6 ms, queue p95 was 0.2 ms,
and failures were zero. The 40.0 ms queue maximum included setup/focus events and
cannot be assigned to an individual Space. All 40 guest increments were visible.
`currentDrawable` acquisition p95/max was 0.5/1.8 ms at that endpoint, 1.0/10.0 ms
after canvas motion, 1.0/12.2 ms at the first video endpoint, and 0.2/10.4 ms at
the 30 FPS endpoint. Later inspection while the first video continued raised its
maximum to 15.8 ms. None reproduced a one-second block. Drawable misses, GPU busy
skips, presentation errors, and GPU errors remained zero.

Canvas motion required approximately 105.0 Mbit/s of accepted display reads;
the 30 FPS video observation averaged approximately 86.7 Mbit/s. This supports
investigating desktop return bandwidth pressure on slower links. It does not
isolate guest/server scheduling, encoding, network buffering, or adaptation, and
does not measure a per-input end-to-end delay.

## Implemented diagnostics and validation

- Added fixed-size Display transport/message counters, with DRAW_COPY image
  categories and separate stream requests/data counts. Requests are counted
  after protocol decode and before execution; they are not successful-decoder
  counts. No image contents, names, credentials, or per-frame logs are retained.
- Added canonical-slot GPU synchronization attempt count and total elapsed wait.
  Existing no-source/in-place/full-overwrite paths remain uncounted. Rendering,
  frame ownership, coalescing, input, codec, and drawable acquisition behavior
  were not optimized or changed.
- Maspice now displays these metrics and the existing drawable stage timings.
  Connected displays expose zero video activity in the UI and copied summary.
- Added benchmark fixture transfer phase, sent-byte progress, and fixed failure
  categories; underlying file paths and error strings are not printed.
- Regression checks cover transport read-ahead counted once, JPEG drawing versus
  MJPEG streaming, migration rollback accounting, retained-frame immutability,
  full-overwrite/in-place copy exclusions, diagnostic rebasing, zero-video
  summaries, and error redaction.
- SwiftSpice: 743 tests passed with warnings treated as errors; optimized build
  passed. Maspice: 57 tests passed; local Release app assembly, signing, and
  dependency audit passed. The final rollback accounting refinement followed
  the live measurements and does not affect their migration-free path; no
  rendering speedup or before/after latency improvement is claimed.
- Original Maspice was reconnected and the original marker restored fullscreen,
  count zero. The installed bundle was not replaced. No push or release occurred.

## Fixture transfer finding

The 404 KB self-contained video page was accepted but timed out after 25 seconds
in the sending phase, with 32,000 bytes reported sent. This narrows the previous
generic failure to a mid-transfer stall; local open/initial guest acceptance had
already progressed. It does not identify whether tokens, pumping, or guest
handling caused the stall. No runtime flow-control change was made.

Distinct smaller fixtures, 22,977 and 10,316 bytes, completed successfully and
were visibly opened and played. This bypasses that setup limitation for video
classification without asserting that large-file transfer was repaired.

## Subsequent server inspection (user-reported)

The user inspected the remote server and reported:

- Linux Lite is started directly by QEMU; libvirt is not the management path.
- The startup configuration omits `streaming-video`. The
  [QEMU invocation documentation](https://www.qemu.org/docs/master/system/invocation.html)
  specifies that video stream detection defaults to `off`.
- The SPICE library accepts `spice:mjpeg` but rejects `gstreamer:h264`, explicitly
  reporting no GStreamer encoder support. The
  [SPICE host video encoding documentation](https://www.spice-space.org/spice-user-manual.html#_host_video_encoding)
  states that host codecs beyond native MJPEG require GStreamer support at build
  time.

These server checks were supplied by the user, not independently executed by
this agent. Raw server command output, library versions, and binary hashes were
not collected in this measurement record. The original evidence archive remains
an immutable record of the earlier client observations; this report and its
machine-readable record include the later server findings separately.

The reported default `off` supplies a configuration explanation for the absent
video streams. The missing GStreamer support is a separate capability limit:
changing detection to `all` or `filter` cannot add H.264 encoding to this build.
This resolves the video-path setup question, not the historical one-second
selection-to-commit outlier.

## Next adjustment and acceptance gate

First compare the current desktop-drawing baseline with `streaming-video=all`
using the existing native MJPEG encoder. Preserve the other QEMU options, TLS
validation, resolution, workload, and network profile. Require nonzero MJPEG
stream-create/data and MJPEG decoder counters before treating the run as an
MJPEG-stream result. Changing the mode alone does not establish that a workload
actually triggered streaming.

Repeat the marker, motion, and fullscreen video workloads and compare received
bytes, local stages, actual input-to-present traces, CPU cost, and text/image
quality. A lower byte rate alone is not an acceptance criterion. After that
baseline, compare `filter` against `all` to evaluate stream detection and quality
tradeoffs for desktop use.

For a future H.264 comparison, first provide a SPICE server built with GStreamer
support and an available compatible H.264 encoder, verify that the requested
encoder is accepted, and then require nonzero H.264 stream/decoder counters.
Confirm VideoToolbox hardware use separately on the client. No server startup
configuration, package, client codec policy, or production rendering behavior
was changed in response to this report; the new MJPEG comparison remains pending.
