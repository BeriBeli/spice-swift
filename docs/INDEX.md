# SwiftSpice documentation index

Start with the root [README](../README.md) to build the package, run the viewer,
or connect the library to a SPICE endpoint.

## Project documents

| Document | Contents |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Module boundaries, concurrency, protocol safety, rendering, and host-resource rules |
| [STATUS.md](STATUS.md) | Current implementation, recent evidence, and remaining validation limits |
| [STREAM_FEEDBACK.md](STREAM_FEEDBACK.md) | Display stream-report contract, source comparison, and validation |
| [REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md) | Directory ownership and file-placement rules |

## Operational guides

| Document | Contents |
| --- | --- |
| [BENCHMARKS.md](../Benchmarks/BENCHMARKS.md) | Local Release workloads, baseline comparison, and input provenance |
| [Native JPEG measurements](../Benchmarks/NativeJPEG/README.md) | Scalar/Neon correctness, native ASan, and same-load decode measurements |
| [QUIC codec contract](../Sources/CSpiceQUIC/README.md) | spice-gtk C codec, bounded application bridge, provenance and native validation |
| [NATIVE_DEPENDENCIES.md](../Artifacts/NATIVE_DEPENDENCIES.md) | Reproducible native XCFramework inputs |

## Status language

- **Implemented** means the code path exists and has focused local tests.
- **Locally verified** means unit, corpus, or offline golden-fixture checks cover
  the behavior.
- **Interoperability verified** means the repository exercised the behavior
  against a live external SPICE peer or real host resource.

A passing local test does not close an external interoperability gate.
[STATUS.md](STATUS.md) records that boundary feature by feature.
