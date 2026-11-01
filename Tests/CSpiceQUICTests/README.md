# Native spice-gtk QUIC validation

Run `./Scripts/validate-quic.sh` (or `make quic`) from the repository root.
This gate needs Xcode and Python. It first verifies the
checked-in native closure, then compiles one C consumer against the unchanged
upstream header and links it separately to the independent C oracle and the
shipped spice-gtk 0.42 QUIC artifact.

`reference.py` fetches checksum-verified spice-common commit
`71e45706981973014eaab3d4b533d35d79e19ffa`; its QUIC codec files match those in
spice-gtk 0.42. Only platform macro headers are supplied locally. The oracle
keeps assertions enabled and is built with ASan/UBSan alongside the consumer.
The prebuilt production archive is not sanitizer-instrumented.

The consumer checks 864 pixel/guard cases across all five formats and eight
conversions, signed/padded strides, chunked I/O, row batches, exact encoded
bytes, 96 allocation-failure trials, truncated input, callback failures,
`longjmp` cleanup and context reuse. RGB16 rows retain the two-byte alignment
required by upstream's scalar accesses. Both implementations must produce the
same complete output; failures and allocator guards are checked independently.
The generated report is `.build/quic-validation/report.json`.

`Tests/SpiceCodecsTests/QUICDecoderTests.swift` and
`Tests/SpiceCoreTests/DisplayChannelTests.swift` exercise the application bridge,
exact fixture pixels, dimension limits, truncated payloads and Surface rollback.
