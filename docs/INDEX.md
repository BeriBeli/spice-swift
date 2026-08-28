# SwiftSpice documentation index

Start with the root [README](../README.md) to build the package, run the viewer,
or connect the library to a SPICE endpoint.

## Project documents

| Document | Contents |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Module boundaries, concurrency, protocol safety, rendering, and host-resource rules |
| [STATUS.md](STATUS.md) | Detailed implementation evidence and the boundary between local and external validation |
| [ROADMAP.md](ROADMAP.md) | Pending work, external gates, and acceptance commands |
| [ALGORITHM_IMPROVEMENT_PLAN.md](ALGORITHM_IMPROVEMENT_PLAN.md) | Active algorithm work, dependencies, completion gates, and evidence log |
| [REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md) | Directory ownership and file-placement rules |

## Operational guides

| Document | Contents |
| --- | --- |
| [APPLE_CONTAINER.md](../Integration/AppleContainer/APPLE_CONTAINER.md) | Local nested QEMU Display, Inputs, and Agent validation |
| [REMOTE_ROCKY.md](../Integration/RemoteRocky/REMOTE_ROCKY.md) | Remote Rocky performance fixture |
| [AUDIO.md](../Integration/RemoteRocky/Audio/AUDIO.md) | Live Playback and Record fixture |
| [VIDEO.md](../Integration/RemoteRocky/Video/VIDEO.md) | Live H.264 and H.265 fixture |
| [WEBDAV.md](../Integration/RemoteRocky/WebDAV/WEBDAV.md) | Live guest WebDAV mount fixture |
| [BENCHMARKS.md](../Benchmarks/BENCHMARKS.md) | Performance comparison and analysis workflow |
| [NATIVE_DEPENDENCIES.md](../Artifacts/NATIVE_DEPENDENCIES.md) | Reproducible native XCFramework inputs |

## Status language

- **Implemented** means the code path exists and has focused local tests.
- **Locally verified** means unit, corpus, or offline golden-fixture checks cover
  the behavior.
- **Interoperability verified** means the repository exercised the behavior
  against a live external SPICE peer or real host resource.

A passing local test does not close an external interoperability gate.
[STATUS.md](STATUS.md) records that boundary feature by feature.
