# MJPEG region ordering correction, 2026-11-14

The [subsequent live A/B/A comparison](PERFORMANCE_MJPEG_REGIONS_LIVE_2026-11-14.md)
is complete. The local-validation cutoff and pending state below are retained
as the record before manual unlock; the live report contains the final results.

The client now accepts delayed video writes to regions that have not been
overwritten. Deterministic tests reproduced and corrected two causes of lost
fragments. Live presentation quality and performance of this change are **not
yet measured**: Computer Use reported that the Mac was locked, and manual unlock
was requested. The installed viewer and remote VM were not restarted in this
follow-up.

This follows the [actual-server comparison](PERFORMANCE_MJPEG_AB_2026-11-14.md).
Its historical measurements are unchanged. The
[machine-readable record](../Benchmarks/Session/RESULTS_MJPEG_REGIONS_2026-11-14.json)
identifies the two executable builds and local checks.

## Reproduced failure

Two streams target disjoint halves of one Surface. The first message has wire
sequence 1, but its decode finishes after sequence 2 on the other half. Previously
the Surface-wide `latestVideoSequence` rejected sequence 1, leaving its half
unchanged. A newer desktop fill on the other half caused the same loss because
the mutation barrier compared the whole Surface's mutation generation.

A four-case pixel regression was run before the production change. Both disjoint
cases failed to commit and left black pixels; both overlapping cases correctly
rejected the stale write. The log contains four failed assertions, from the two
disjoint cases. This establishes a client fragment-loss defect. It does not
establish the sole cause of the previously photographed phase bands, nor the
historical 1,007.6 ms presentation stall.

## Correction and safety

The Surface keeps separate bounded coverage records for committed video and
desktop writes. It compares incoming video only with newer writes intersecting
its validated, captured clip rectangles. The sequence remains Surface-wide, so
overlapping streams still respect wire order. A stale frame intersecting any
newer write is rejected as a whole; the implementation does not split that frame.

Each record retains at most 256 rectangles. A newer covering write replaces older
covered entries, so stable strips do not consume an entry for every frame. Once
coverage is evicted, older observations are conservatively rejected. Oversized
clip lists also advance this conservative history boundary. Lifecycle identity,
nonzero video sequences and valid mutation generations remain required.

Desktop fills, bitmap copies, copy-bits, cross-Surface copies and region mutation
commits record their actual destination coverage. Both CPU-scaled and native
GPU video commits use the same validation. The native path still checks out a
separate writable candidate and commits only after GPU completion; retained
snapshots and failure rollback retain their existing ownership guarantees.

This change does not batch composition or remove full-Surface candidate copies.
Accepting more correct fragments can increase that work. The previous GPU-copy
amplification remains a separate optimization target.

## Local verification

- All **749** SwiftSpice tests passed with warnings as errors, including CPU and
  native video disjoint/overlap cases, retained snapshots, coverage eviction,
  overlapping-stream ordering and desktop overwrite protection.
- The same **749** tests passed under Address Sanitizer.
- The new wire-level two-stream test gates the first decode until the other
  stream has published. Both disjoint destinations and a shared destination with
  disjoint clips preserve both halves after reversed completion. Its timeout is
  an observation failure bound; cleanup releases the decoder before closing.
- All **57** Maspice tests passed with warnings as errors.
- `PACKAGE=0 ./Scripts/build-app.sh` completed the Release app build, native
  dependency audits, bundle assembly and ad hoc signature verification.
- The release dependency pin was restored after editable-package verification.
  No installed application was replaced and no release was published.

## Remaining live acceptance

The preserved control executable SHA-256 is
`4f41f9f2467c59faf2fe43895f336cc3dd4b06933efbb6357dd0145390fe6f0f`.
The corrected Release executable SHA-256 is
`fb0b122f4c2eebd9d028a20de1b16f66ec53f020c38a19e66a18478b6ce0b420`.

After manual Mac unlock, compare these builds under the same explicit
`streaming-video=all` mode, original trusted-TLS connection, 1920×1080 guest and
existing finite full-field fixture. Collect matched Display, decode, native
commit, fallback, GPU-copy, process-resource and drawable observations, plus
forty real marker inputs per build. Fragment counts are not complete-frame FPS;
unaligned screenshots are not a pixel-quality score. Decode-minus-commit counts
alone do not identify individual rejection reasons.

Restore default-off startup, the installed client and fullscreen marker at zero
after the comparison. Until it passes, retain default `off`. No H.264 capability
change or claim about the one-second stall follows from this local fix.
