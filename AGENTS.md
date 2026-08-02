# Repository agent instructions

## Metal and IOSurface test execution

- Run Swift tests that exercise Metal, IOSurface, CoreVideo GPU surfaces, or
  other macOS GPU runtime services outside the filesystem/process sandbox.
- Run the complete Swift test suite outside the sandbox because it includes
  Metal and IOSurface tests:

  ```sh
  swift test --disable-sandbox -Xswiftc -warnings-as-errors
  ```

- Do not classify a sandbox-only timeout, hang, permission error, unavailable
  macOS service, or Metal runtime failure as an application test failure. Stop
  the sandboxed run and repeat it on the host before reporting the result.
- Lightweight checks that do not use Metal or IOSurface may still run inside
  the sandbox.
