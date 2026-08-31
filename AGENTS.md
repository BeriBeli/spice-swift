# AGENTS.md

This file defines repository-wide working rules for coding agents and automated reviewers.

The goal is not maximum cleverness or maximum test volume. The goal is the smallest maintainable change that is correct, portable, reviewable, and supported by evidence.

## 1. Read the repository before changing it

Before editing code:

- Read the relevant implementation, tests, and nearby documentation.
- Follow the existing architecture and naming unless there is a concrete reason to change them.
- Treat `README.md`, `docs/STATUS.md`, and the relevant design/plan documents as context, not as permission to expand scope.
- Distinguish current production behavior from historical benchmark notes and experimental evidence.
- Do not infer requirements from one developer's local setup, shell history, temporary artifact path, host alias, or previous experiment unless that dependency is explicitly part of the supported interface.

Prefer modifying the smallest existing seam that can correctly solve the task.

## 2. Scope discipline

Keep every change focused on the requested behavior.

Do not opportunistically refactor adjacent code, rename unrelated APIs, rewrite documentation, change formatting across files, or add infrastructure that is not required for the task.

If a task reveals a separate issue, leave it separate unless fixing it is necessary for correctness or safety of the requested change.

A change should normally have one primary reason to exist.

## 3. Simplicity and anti-overcoupling

Deep reasoning is encouraged, but discovered complexity must pass an evidence threshold before it becomes code.

Additional reasoning MUST NOT automatically produce additional abstractions, state machines, synchronization machinery, test hooks, observers, or test cases.

Prefer:

1. simpler state models;
2. fewer ownership relationships;
3. fewer concurrency primitives;
4. fewer test-only seams;
5. smaller package/public API surface;
6. fewer special cases;
7. code that can be reasoned about locally.

When two solutions are correct, prefer the one with fewer moving parts.

### Complexity admission rule

Before adding any of the following:

- a new production abstraction;
- a new state or lifecycle layer;
- a test-only hook or observer;
- a latch, semaphore, watchdog, continuation wrapper, fake scheduler, fake worker, or similar synchronization helper;
- another dependency-injection layer;
- multiple helper types for one review finding;

first establish that the existing boundary cannot express or verify a real required property.

If the new mechanism mainly exists to test another test-only mechanism, stop and redesign the test.

A test harness becoming more complicated than the production abstraction is a warning sign, not a reason to keep expanding the harness.

## 4. Classify corner cases before implementing them

For every newly proposed corner case or review finding, classify it as one of:

### A. Real correctness failure

The current implementation can produce incorrect externally observable behavior.

### B. Real safety or resource failure

The current implementation can leak, deadlock, hang without a required bound, corrupt state, double-own or double-close a resource, use a resource after ownership ended, violate protocol guarantees, or affect an unrelated resource.

### C. Test-oracle weakness

Production behavior may already be correct, but the test does not distinguish it from some hypothetical implementation.

### D. Speculative implementation possibility

The concern depends on an implementation strategy the current production code does not use and no concrete externally observable failure is demonstrated.

A and B normally justify implementation or test changes.

For C, first simplify, replace, or raise the abstraction level of the test.

For D, do not add code unless the specification, a reproduced bug, platform behavior, or other independent evidence makes the scenario material.

Reviewer suggestions are hypotheses to evaluate, not instructions to implement mechanically.

## 5. Test behavior, not choreography

Tests should primarily assert externally observable contracts and durable invariants.

Good examples include:

- the correct value or typed error is returned;
- protocol-visible ordering is preserved;
- an operation is bounded where the specification requires a bound;
- a resource is released exactly when ownership semantics require it;
- a closed object causes no further external effects;
- invalid input fails without partially publishing state;
- retries do not duplicate externally visible effects.

Avoid coupling tests to exact internal worker counts, callback entry order, temporary state transitions, private scheduling decisions, or implementation-specific sequencing unless those details are themselves part of the required safety contract.

Prefer one invariant-oriented test over many tests that enumerate equivalent implementation interleavings.

Do not recursively test the test harness.

## 6. Stop condition for testing and review

Do not optimize for "a suite no reviewer can imagine defeating."

Once a change covers:

- the written requirement;
- the main success path;
- relevant protocol/input boundaries;
- known failure paths;
- concrete concurrency/resource hazards;
- regressions for bugs actually found during the task;

stop adding scenarios unless new evidence demonstrates a material missing failure.

A new review iteration by itself is not evidence that more complexity is required.

Before completion, perform a deletion/simplification pass and ask:

- Can a helper or state variable be removed?
- Can multiple mechanisms collapse into one?
- Can a fake be replaced by a simpler real boundary?
- Can several cases be expressed as one invariant?
- Is any assertion testing implementation rather than behavior?
- Did a review-driven fix add more complexity than the failure it prevents?

Prefer deleting unnecessary code over documenting why unnecessary code exists.

## 7. Portability: never bind the repository to one developer's machine

Repository behavior must not depend on one contributor's workstation layout or personal environment.

Do not commit new dependencies on:

- usernames;
- home-directory paths such as `/Users/<name>/...` or `/home/<name>/...`;
- a developer's repository checkout location;
- personal host aliases;
- local-only DNS names;
- specific temporary directories;
- shell aliases or shell startup files;
- editor-specific state;
- untracked files;
- machine-specific absolute paths;
- locally installed Homebrew paths or other package-manager prefixes unless explicitly part of a documented supported build interface;
- a secret, credential, ticket, token, private key, or personal account identifier.

Use repository-relative paths where possible.

For runtime or integration locations that genuinely vary by machine, use explicit configuration through command-line arguments, environment variables, configuration files, or generated temporary directories with safe defaults.

Defaults must be generic and documented. A historical experiment path may be recorded as evidence in a benchmark/result document, but production code, reusable scripts, tests, and active workflow configuration must not require that historical path to exist.

Host aliases such as RemoteRocky targets must be inputs, not baked-in assumptions, unless the repository explicitly defines them as fixture identifiers.

Do not make tests pass only because files or tools happen to exist outside the repository.

## 8. Environment and path hygiene

Scripts should resolve their own repository root rather than assuming the caller's current working directory when practical.

Quote shell paths and variables correctly.

Use `mktemp` or an equivalent controlled temporary location for transient state instead of fixed globally shared paths unless a stable path is explicitly required for cross-process coordination.

Transient files must have clear ownership and cleanup behavior.

Do not write outside the repository or an explicitly configured temporary/output directory unless the operation is an intentional integration effect documented by the task.

Do not silently normalize a path when the path itself is part of an identity or safety boundary; validate it according to the owning interface instead.

## 9. Dependencies and build reproducibility

Avoid adding dependencies when the standard library or an existing repository dependency is sufficient.

New dependencies require a concrete benefit that outweighs maintenance, supply-chain, binary-size, build-time, and portability cost.

Do not introduce an implicit runtime dependency on tools that are only present on the current development machine.

The repository's checked-in native artifacts and documented toolchain are the supported dependency boundary. Preserve relocatability and existing native-closure checks.

Generated files must be produced through the repository's generator. Do not hand-edit generated output unless the repository explicitly marks that file or region as manually maintained.

## 10. Swift and concurrency rules

Follow Swift 6 strict-concurrency semantics rather than suppressing diagnostics.

Do not add `@unchecked Sendable`, unsafe global state, detached tasks, locks, atomics, or continuation-based bridges merely to silence the compiler or make a test convenient.

If such a primitive is genuinely required, document the ownership invariant in the code and keep the protected state minimal.

Prefer structured concurrency when it correctly models lifetime. Use unstructured tasks only when their independent lifetime is intentional and bounded by explicit ownership.

Task cancellation is cooperative. Do not assume cancellation interrupts blocking Darwin, Dispatch, continuation-backed, or foreign-library work. If cancellation must unblock external work, design an explicit ownership/close/cancel mechanism at the appropriate boundary.

Do not hold a lock across an `await`.

Avoid encoding scheduling accidents as correctness requirements.

## 11. Resource ownership

For file descriptors, sockets, processes, continuations, buffers, temporary files, and other owned resources, make ownership explicit.

A resource should have one authoritative owner at a time.

Transfer, close, cancel, reap, and cleanup operations must be idempotent where repeated calls are part of the public/package contract.

Do not add elaborate ownership machinery for hypothetical cases, but do cover concrete risks such as leaks, double close, stale-owner effects, and unbounded blocked work when those risks exist in the implementation.

Cleanup code must not depend on a successful happy-path assertion having already run.

## 12. Errors and fail-closed behavior

Preserve typed errors when callers or tests rely on their semantics.

Do not catch broad errors and silently continue across state-changing or persistence boundaries.

If an external effect may have occurred but its durable result is uncertain, do not retry automatically unless the protocol explicitly defines an idempotent retry mechanism.

Avoid turning internal implementation errors into public protocol behavior without an explicit API reason.

## 13. Security and sensitive data

Never commit secrets or sensitive runtime material.

Do not log or persist SPICE tickets, passwords, authentication material, clipboard content, private keys, or other sensitive payloads unless the product requirement explicitly calls for it and the storage/logging policy is defined.

Prefer metadata, bounded counters, fixed error categories, and redacted diagnostics over payload capture.

Keep command-line secrets out of process listings when an environment variable, protected file descriptor, or mode-0600 temporary file is the existing supported mechanism.

## 14. Documentation must describe evidence, not aspiration

Do not claim a feature, performance improvement, interoperability result, release status, or platform behavior that was not actually demonstrated.

Distinguish clearly between:

- implemented locally;
- covered by deterministic tests;
- validated in CI;
- exercised against a real external SPICE peer;
- measured in a benchmark;
- still pending external/hardware/live validation.

Historical benchmark evidence may record exact hosts, paths, run IDs, commits, and artifacts when needed for auditability. Do not copy those historical values into active reusable code as defaults.

When updating `docs/STATUS.md`, benchmark results, or algorithm plans, preserve this distinction.

Do not rewrite historical evidence merely to make the current design look cleaner.

## 15. Performance work requires measurement

Do not make a performance optimization because it "should be faster" without identifying the cost being removed.

Keep correctness changes and performance experiments separable when possible.

Do not add caches, batching, lock-free structures, atomics, custom allocators, concurrency, or GPU paths solely from intuition.

For performance claims, use reproducible measurements and record enough context to compare results meaningfully.

A benchmark-specific environment may be specialized, but the library and general build/test workflow must remain independent of that benchmark host.

## 16. Repository verification baseline

Use the narrowest relevant check while iterating, then run the appropriate repository gate before declaring completion.

The documented baseline includes:

```sh
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift package --allow-writing-to-package-directory generate-spice-protocol --check
./Scripts/build-lib.sh
./Scripts/analyze-c-shims.sh
./Scripts/test-address-sanitizer.sh
./Scripts/check-code-coverage.sh
```

The `Makefile` is a thin task runner over `Scripts/`; scripts remain the source of truth.

Do not claim a command passed unless it was actually run successfully in the current relevant environment.

If a full gate cannot be run, state exactly what was and was not verified.

Do not weaken tests, warnings-as-errors, sanitizer checks, coverage thresholds, or protocol-generation checks merely to make a change pass.

## 17. Test determinism

Do not use arbitrary sleeps as synchronization when a deterministic event or state boundary is available.

Timeouts are failure bounds, not synchronization mechanisms.

Tests that exercise blocking resources must have bounded failure cleanup so a broken implementation does not hang the whole suite.

At the same time, do not build a miniature scheduler or operating system inside tests merely to enumerate every theoretical ordering. Use the simplest deterministic seam that proves the material invariant.

## 18. Generated, vendored, and artifact content

Respect ownership boundaries for generated and third-party content.

Do not casually modify checked-in binary/native artifacts, protocol-generated files, benchmark evidence, or vendored code as part of an unrelated task.

If a native artifact changes, preserve provenance, checksum, architecture, license, and relocatability requirements.

Do not commit local build output, temporary logs, crash dumps, derived data, ad-hoc captures, or machine-specific generated state.

## 19. Git and pull-request discipline

Do not push, merge, tag, publish a release, rewrite history, or modify unrelated branches unless explicitly requested.

Keep commits reviewable and scoped.

Do not include generated noise or unrelated formatting in a functional change.

PR descriptions should state:

- what behavior changed;
- why the change is needed;
- the important invariants;
- what verification actually ran;
- what remains intentionally out of scope.

Do not inflate a PR description with every hypothetical property considered during reasoning.

Review comments should prioritize material issues over theoretical completeness.

## 20. Review policy for automated reviewers

When reviewing, prioritize:

1. specification violations;
2. concrete correctness bugs;
3. security and resource-ownership failures;
4. reachable concurrency bugs;
5. portability/reproducibility regressions;
6. missing coverage for important externally observable invariants;
7. unnecessary complexity that can be removed.

Do not report a finding solely because a hypothetical alternative implementation could pass the existing tests.

Do not require tests to distinguish every theoretically incorrect implementation.

Do not ask for more instrumentation merely to make a test oracle more implementation-specific.

If a proposed finding would require substantial new test-only machinery, first ask whether the property is material and whether the test should instead be simplified.

Prefer one material finding over several speculative completeness suggestions.

## 21. Completion checklist

Before finishing a change, verify:

- The requested behavior is implemented and scope did not drift.
- No developer-specific path, host, secret, or local state was introduced.
- The implementation uses the smallest reasonable state and ownership model.
- Tests cover behavior and material safety invariants rather than private choreography.
- No test-only infrastructure recursively verifies itself.
- Error and cleanup paths are bounded where required.
- Documentation claims match actual evidence.
- Relevant generators and verification commands were run.
- A final simplification/deletion pass was performed.

The preferred end state is boring code with strong invariants, portable inputs, reproducible verification, and no unnecessary machinery.
