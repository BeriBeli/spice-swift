# 2026-08-03 Rocky benchmark evidence

This directory retains separate archives for the historical
selected-Swift-renderer versus GLib run and the later direct
`cpu-iosurface` versus `metal` follow-up. Do not combine their samples into a
synthetic result.

## Selected Swift renderer versus GLib

`swiftspice-pr4-d68a8ec-rocky-results.tar.gz` is the sanitized evidence archive
for `Benchmarks/RESULTS_ROCKY8_2026-08-03.md`.

- Tested code: `d68a8ec7502421b5bd5bdfa16804ea2b839a7a63`
- Archive SHA-256:
  `b71b301b6cf3d5e374055681a928ffdee2b3073e2e0d1fe5c5d56b296e5c2b18`
- Raw sets: CPU/GLib and Metal/GLib at 1280x720 and 3840x2160, ten requested
  30-second pairs each.
- Diagnostic sets: activity-valid pair selections used by the report: 8, 7,
  8, and 8 pairs respectively.
- Preflight set: the 3840x2160 ten-pair, five-second activity stress that
  completed with 20/20 activity-valid samples.

This archive contains every `run-*.json`, `run-*.meta.json`, and
`run-*.time.txt` file, each raw set's `integrity-failures.tsv`, analyzer output
and exit status, the exact tested analyzer and live runner, a manifest with Git
blob IDs, and per-file SHA-256 checksums. It excludes the generated GLib binary
and contains no SPICE password, ticket, token, or authorization field.

The raw four-batch analyzer outputs intentionally fail because their retained
`integrity-failures.tsv` files make the formal evidence invalid. The diagnostic
set outputs reproduce the report's pairwise ratios and confidence intervals;
their analyzer exit status remains nonzero when a performance gate fails.

## Direct CPU-IOSurface versus Metal

`swiftspice-pr4-bb3b176-direct-renderer-results.tar.gz` is the sanitized
evidence archive for
`Benchmarks/RESULTS_DIRECT_ROCKY8_2026-08-03.md`.

- Tested code: `bb3b1768f1cd885ed45e120a55ffa23afc0d9d2d`
- Archive SHA-256:
  `e4af602279fb51089c46333c82f4762b9cb7639690d27c52cb6dee4f82903edb`
- Raw sets: direct CPU-IOSurface/Metal batches at 1280x720 and 3840x2160,
  ten requested 30-second pairs each.
- Diagnostic sets: the contiguous activity-valid prefixes, pairs 1-5 at 720p
  and pairs 1-6 at 4K.
- Smoke sets: one five-second pair at each resolution.

The direct archive preserves all renderer JSON, metadata, and resource samples;
integrity failures; exact per-round server logs, guest generator telemetry,
configuration, and versions; fixture manifests; analyzer outputs and exit
codes; the exact tested direct runner/analyzers; the archive tool; and per-file
checksums. The full raw batches and every diagnostic prefix intentionally have
nonzero renderer-analyzer status, while all six guest-telemetry analyses pass.

## Verification

Verify either archive and its internal checksums with:

```sh
shasum -a 256 ARCHIVE.tar.gz
tar -xzf ARCHIVE.tar.gz
cd swiftspice-benchmark-evidence
shasum -a 256 -c SHA256SUMS
jq . manifest.json
```
