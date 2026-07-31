# SwiftSpice documentation

Start with the root [README](../README.md) to build the package, run the viewer,
or connect the library to a SPICE endpoint.

## Guides

| Document | Use it for |
| --- | --- |
| [Architecture and roadmap](PLANS.md) | Module boundaries, concurrency rules, protocol safety, and planned work |
| [Current milestone](CURRENT_MILESTONE.md) | Detailed implementation evidence, acceptance commands, and pending external gates |
| [Apple/container live-validation harness](../Integration/AppleContainer/README.md) | Reproducing live QEMU Display, Inputs, Agent, clipboard, file-transfer, and monitor checks |

## Status language

The documentation uses three distinct levels of confidence:

- **Implemented** means the code path exists and has focused local tests.
- **Locally verified** means unit, corpus, or offline golden-fixture checks cover
  the behavior.
- **Interoperability verified** means the repository exercised the behavior
  against a live external SPICE peer or real host resource.

A passing local test does not close an external interoperability gate. The
[current milestone](CURRENT_MILESTONE.md) records that boundary feature by
feature.
