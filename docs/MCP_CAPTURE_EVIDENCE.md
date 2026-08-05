# MCP bounded frame capture evidence

Status: local upstream candidate on `codex/mcp-a3-capture`; not tagged, released,
or integrated into the app-side MCP service.

## Contract

- `SpiceFrameCapturer` accepts an optional pixel-aligned crop, output edge/pixel
  budgets, and an explicit cursor-compositing flag.
- The default edge budget is 1280 pixels. Requests cannot raise the hard limits
  above 2048 pixels per edge or 1,200,000 output pixels. The public capture path
  fixes the normal PNG response limit at 2 MiB; 6 MiB remains an absolute
  defensive ceiling rather than an attainable normal target.
- Invalid regions, unsupported cursor formats, cancellation, encoding failure,
  and byte-budget rejection are distinct fail-closed outcomes.
- Crop coordinates use the SPICE frame's top-left origin.
- Cursor tests cover include/exclude behavior, non-zero hotspots, partial clipping,
  and a fully out-of-bounds cursor.
- The revisioned IOSurface path locks the committed IOSurface and renders from it
  directly; it does not request `SpiceFrame.pixels`. The existing CPU path stays
  available as the correctness fallback.
- Only the bounded output bitmap is materialized before PNG encoding. This is not
  evidence of Metal acceleration or a CPU-versus-GPU performance improvement.

## Host evidence

Run on Apple Silicon macOS with warnings treated as errors and isolated module
and build caches.

Focused real-IOSurface gate:

```sh
SPICE_CAPTURE_4K_HOST_TEST=1 \
CLANG_MODULE_CACHE_PATH=/private/tmp/maspice-a3-new-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/maspice-a3-new-swiftpm \
swift test --disable-sandbox \
  --scratch-path /private/tmp/maspice-a3-new-build \
  -Xswiftc -warnings-as-errors \
  --filter SpiceFrameCapturerTests
```

Result on 2026-08-04: 10 tests in 1 suite passed. Both the 1920x1080 CPU case and
the 3840x2160 revisioned IOSurface case produced 1280x720 PNGs within 2 MiB. The
4K IOSurface case left
`cpuMaterializations` unchanged. Releasing the caller's frame and destroying the
source surface after capture returned the revisioned pool's in-flight lease count
to zero, showing that the capturer did not retain the source lease.

Full regression gate, with the intentionally heavy 4K case disabled by default:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/maspice-a3-new-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/maspice-a3-new-swiftpm \
swift test --disable-sandbox \
  --scratch-path /private/tmp/maspice-a3-new-build \
  -Xswiftc -warnings-as-errors
```

Result on 2026-08-04: 412 tests in 70 suites passed.

The 4K case is a separate opt-in host gate because running that allocation and
PNG encode concurrently with the full suite can consume the timing margin of
unrelated 100 ms lifecycle tests. The focused gate requires successful real
IOSurface allocation and does not silently skip when enabled.
