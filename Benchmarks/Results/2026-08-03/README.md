# 2026-08-03 Rocky benchmark evidence

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

The archive contains every `run-*.json`, `run-*.meta.json`, and
`run-*.time.txt` file, each raw set's `integrity-failures.tsv`, analyzer output
and exit status, the exact tested analyzer and live runner, a manifest with Git
blob IDs, and per-file SHA-256 checksums. It excludes the generated GLib binary
and contains no SPICE password, ticket, token, or authorization field.

Verify and inspect it with:

```sh
shasum -a 256 swiftspice-pr4-d68a8ec-rocky-results.tar.gz
tar -xzf swiftspice-pr4-d68a8ec-rocky-results.tar.gz
cd swiftspice-benchmark-evidence
shasum -a 256 -c SHA256SUMS
jq . manifest.json
```

The raw four-batch analyzer outputs intentionally fail because their retained
`integrity-failures.tsv` files make the formal evidence invalid. The diagnostic
set outputs reproduce the report's pairwise ratios and confidence intervals;
their analyzer exit status remains nonzero when a performance gate fails.
