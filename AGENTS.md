# AGENTS.md

Repository-wide rules for coding agents and automated reviewers. Prefer the
smallest maintainable change supported by evidence.

## Scope and repository context

Read the relevant implementation, tests, and nearby documentation before editing.
Follow existing architecture and naming; keep unrelated refactors separate.

- `README.md`: supported toolchain, build commands, and public usage.
- `docs/ARCHITECTURE.md` and `docs/REPOSITORY_LAYOUT.md`: module boundaries and file placement.
- `docs/STATUS.md`: implementation evidence and pending external validation.
- Design plans and benchmark records provide context, not permission to expand scope
  or treat historical experiments as current production requirements.

## Simplicity, tests, and review

New abstractions, state, or synchronization mechanisms should solve a concrete
problem and justify their overall complexity. Prefer existing boundaries and
fewer ownership relationships, especially in test infrastructure.

Tests should assert observable behavior and material safety invariants, not
private scheduling or callback choreography. Use deterministic events for
synchronization; timeouts are failure bounds. Blocking-resource tests must clean
up on failure without hanging the suite.

Review findings and fixes should be grounded in reachable failures in the current
implementation, explicit contracts, or independent evidence. Do not add machinery
solely to distinguish hypothetical implementations or recursively test a harness.
Evaluate reviewer suggestions rather than applying them mechanically.

Once requirements, relevant boundaries, known failures, and concrete concurrency
or resource hazards are covered, stop adding scenarios unless new evidence shows
a material gap. Before finishing, remove unnecessary helpers, state, and tests.

## Portability and owned artifacts

Production code, reusable scripts, and tests must not depend on a developer's
paths, host aliases, installed tools, or untracked local state. Use repository-
relative paths and explicit configuration for machine-dependent integration
inputs. Scripts should resolve their repository root and use owned temporary
locations with cleanup. Historical paths and hosts may remain in evidence records.

The checked-in native artifacts and documented toolchain define the supported
dependency boundary. Avoid new dependencies when existing facilities suffice.
Preserve native artifact provenance, checksums, architecture, licenses, and
relocatability checks. Generate protocol output through the repository generator;
do not hand-edit generated or vendored content as part of unrelated changes.

## Swift concurrency and resource ownership

Follow Swift 6 strict concurrency. Do not introduce `@unchecked Sendable`,
detached tasks, locks, atomics, or continuation bridges merely to silence
compiler diagnostics or simplify a test. When needed, document the ownership
invariant and keep protected state minimal. Never hold a lock across `await`.
Unstructured tasks need intentional lifetime ownership.

Task cancellation does not automatically interrupt blocking Darwin, Dispatch,
or foreign-library work. Where cancellation must unblock work, use an explicit
close/cancel mechanism at the owning boundary.

Keep ownership of sockets, file descriptors, processes, buffers, and continuations
explicit. Cleanup must work on failure; repeated cleanup must be safe where the
contract permits it. Preserve typed errors and do not silently continue after
state-changing failures. Do not automatically retry an uncertain external effect
unless the protocol supports idempotent retry.

## Sensitive data and evidence

Do not log, persist, or commit SPICE tickets, credentials, clipboard content, or
other sensitive payloads without an explicit product requirement and storage
policy. Prefer bounded metadata and fixed error categories; keep secrets out of
command-line arguments.

Distinguish local implementation, deterministic tests, CI, real SPICE peer
interoperability, hardware validation, and benchmark measurements in documentation.
Preserve historical evidence and mark pending gates honestly. Performance changes
must identify the cost being removed; improvement claims require reproducible
measurements. Benchmark-specific setup must not become a library dependency.

## Verification

Choose local checks by the changed behavior:

- Documentation-only changes: check the diff and referenced paths or commands;
  no Swift build or test run is required.
- Swift changes: run warnings-as-errors builds and relevant tests; broaden to the
  full suite for shared behavior. Use sanitizer checks for memory/resource changes.
- Protocol schema or generator changes: run the generation consistency check.
- C shims or native artifacts: run the relevant build, analysis, sanitizer, and
  native-closure checks.
- Build or verification workflow changes: exercise the affected scripts or gates.

The full baseline is documented in `README.md` and implemented by
`.github/workflows/ci.yml`; `make all` runs the local aggregate gate. CI runs its
full baseline on PRs and pushes to `main`, including documentation-only changes.
`Scripts/` remains the source of truth for script behavior; the Makefile is a
thin task runner.

Common checks:

```sh
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift package --allow-writing-to-package-directory generate-spice-protocol --check
./Scripts/build-lib.sh
./Scripts/analyze-c-shims.sh
./Scripts/test-address-sanitizer.sh
./Scripts/check-code-coverage.sh
```

Report what actually ran and any relevant checks still pending. Do not weaken
warnings, tests, sanitizer checks, coverage thresholds, or generator checks to
make a change pass.

## Git and delivery

Commits, pushes, and merges are authorized within the current task's scope;
no additional confirmation is needed. Before merging, verify the intended target
and that required checks and repository review requirements are satisfied.
Keep commits scoped and preserve unrelated user changes.

Tags, release publication, history rewriting (including force pushes), and changes
to unrelated branches still require explicit user authorization.
