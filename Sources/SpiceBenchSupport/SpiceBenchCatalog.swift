import Foundation
import SpiceCodecs
import SpiceRenderer
import SpiceWire

package enum SpiceBenchCatalog {
    package static let workloadID = "aip-00.micro.v2"

    package static let stableCaseIDs = [
        "wire.contiguous",
        "wire.fragmented",
        "region.normalization",
        "copy_bits",
        "lz",
        "glz",
        "iosurface.transition",
        "advanced_video.sample",
    ]

    private struct WireFixture: Sendable {
        let bodyByteCount: Int
        let wire: Data
    }

    private struct FragmentedWireFixture: Sendable {
        let bodyByteCount: Int
        let segments: [Data]
    }

    private struct CopyBitsFixture: Sendable {
        let destination: PixelRect
    }

    private struct Fixtures: Sendable {
        let contiguousWire: WireFixture
        let fragmentedWire: FragmentedWireFixture
        let regionDestination: PixelRect
        let regionClips: [PixelRect]
        let surfaceBitmap: RawBitmap
        let copyBits: CopyBitsFixture
        let ioSurfaceBitmap: RawBitmap
        let codecDescriptor: SpiceCodecImageDescriptor
        let overlapReferencePixels: UInt64
        let lzDecoder: SpiceLZDecoder
        let lzPayload: Data
        let glzPayload: Data
        let videoParser: SpiceAnnexBParser
        let videoPayload: Data

        init() {
            let wireBody = SpiceBenchCatalog.deterministicBytes(count: 256 * 1_024)
            let wire = SpiceBenchCatalog.miniMessage(type: 7, body: wireBody)
            contiguousWire = WireFixture(bodyByteCount: wireBody.count, wire: wire)
            let splitPoints = [1, 3, 6, 65_537, wire.count]
            var segments: [Data] = []
            segments.reserveCapacity(splitPoints.count)
            var start = 0
            for end in splitPoints where end > start {
                segments.append(Data(wire[start ..< end]))
                start = end
            }
            fragmentedWire = FragmentedWireFixture(
                bodyByteCount: wireBody.count,
                segments: segments
            )

            let destination = PixelRect(x: 0, y: 0, width: 1_024, height: 1_024)
            regionDestination = destination
            var clips: [PixelRect] = []
            clips.reserveCapacity(512)
            for index in 0 ..< 256 {
                let x = index * 4
                clips.append(PixelRect(x: x, y: 0, width: 2, height: 1_024))
                clips.append(PixelRect(x: x, y: 128, width: 1, height: 768))
            }
            regionClips = clips

            let surfaceWidth = 256
            let surfaceHeight = 128
            surfaceBitmap = RawBitmap(
                format: .argb8888,
                width: surfaceWidth,
                height: surfaceHeight,
                stride: surfaceWidth * 4,
                topDown: true,
                pixels: SpiceBenchCatalog.deterministicBytes(
                    count: surfaceWidth * surfaceHeight * 4
                )
            )
            let copyDestination = PixelRect(
                x: 0,
                y: surfaceHeight / 2,
                width: surfaceWidth,
                height: surfaceHeight / 2
            )
            copyBits = CopyBitsFixture(
                destination: copyDestination
            )

            let ioSurfaceWidth = 128
            let ioSurfaceHeight = 128
            ioSurfaceBitmap = RawBitmap(
                format: .argb8888,
                width: ioSurfaceWidth,
                height: ioSurfaceHeight,
                stride: ioSurfaceWidth * 4,
                topDown: true,
                pixels: SpiceBenchCatalog.deterministicBytes(
                    count: ioSurfaceWidth * ioSurfaceHeight * 4
                )
            )

            let codecWidth = 16_384
            let codecHeight = 1
            codecDescriptor = SpiceCodecImageDescriptor(width: codecWidth, height: codecHeight)
            overlapReferencePixels = UInt64(codecWidth - 1)
            lzDecoder = SpiceLZDecoder()
            lzPayload = SpiceBenchCatalog.lzRGBPayload(
                width: codecWidth,
                height: codecHeight
            )
            glzPayload = SpiceBenchCatalog.glzRGBPayload(
                width: codecWidth,
                height: codecHeight
            )
            videoParser = SpiceAnnexBParser()
            var annexB = Data([0, 0, 0, 1, 0x65])
            annexB.append(SpiceBenchCatalog.deterministicBytes(count: 64 * 1_024))
            videoPayload = annexB
        }
    }

    private actor CopyBitsBenchmarkState {
        struct Result: Sendable {
            let revision: SurfaceRevision
            let before: SurfaceStoreMetrics
            let after: SurfaceStoreMetrics
        }

        private var store: SurfaceStore?
        private var metricsBeforeCopy: SurfaceStoreMetrics?
        private var region: PixelRegion?

        func setUp(bitmap: RawBitmap, fixture: CopyBitsFixture) async throws {
            await tearDown()
            let store = SurfaceStore(backingPolicy: .dataOnly)
            do {
                try await store.create(
                    id: 1,
                    width: UInt32(bitmap.width),
                    height: UInt32(bitmap.height),
                    format: SurfacePixelFormat.argb8888.rawValue
                )
                _ = try await store.drawCopy(
                    surfaceID: 1,
                    destination: PixelRect(
                        x: 0,
                        y: 0,
                        width: bitmap.width,
                        height: bitmap.height
                    ),
                    bitmap: bitmap
                )
                metricsBeforeCopy = await store.metrics()
                region = try PixelRegion(
                    destination: fixture.destination,
                    surfaceBounds: PixelRect(
                        x: 0,
                        y: 0,
                        width: bitmap.width,
                        height: bitmap.height
                    ),
                    clips: nil
                )
                self.store = store
            } catch {
                await store.close()
                throw error
            }
        }

        func run(fixture: CopyBitsFixture) async throws -> Result {
            guard let store, let metricsBeforeCopy, let region else {
                throw SpiceBenchWorkloadError.missingState("COPY_BITS")
            }
            guard let revision = try await store.copyBits(
                surfaceID: 1,
                region: region,
                destination: fixture.destination,
                sourceX: 0,
                sourceY: 0
            ) else {
                throw SpiceBenchWorkloadError.missingOutput("COPY_BITS revision")
            }
            return Result(
                revision: revision,
                before: metricsBeforeCopy,
                after: await store.metrics()
            )
        }

        func tearDown() async {
            let store = self.store
            self.store = nil
            metricsBeforeCopy = nil
            region = nil
            await store?.close()
        }
    }

    private actor GLZBenchmarkState {
        struct Result: Sendable {
            let image: SpiceDecodedImage
            let diagnostics: SpiceGLZDecoderDiagnostics
        }

        private var decoder: SpiceGLZDecoder?

        func setUp() async {
            await tearDown()
            decoder = SpiceGLZDecoder()
        }

        func run(
            descriptor: SpiceCodecImageDescriptor,
            payload: Data
        ) async throws -> Result {
            guard let decoder else {
                throw SpiceBenchWorkloadError.missingState("GLZ")
            }
            let image = try await decoder.decode(descriptor: descriptor, payload: payload)
            return Result(
                image: image,
                diagnostics: await decoder.diagnosticsSnapshot()
            )
        }

        func tearDown() async {
            let decoder = self.decoder
            self.decoder = nil
            await decoder?.clear()
        }
    }

    private actor IOSurfaceBenchmarkState {
        struct Result: Sendable {
            let revision: SurfaceRevision
            let beforeCopy: SurfaceStoreMetrics
            let beforeMutation: SurfaceStoreMetrics
            let after: SurfaceStoreMetrics
        }

        private var store: SurfaceStore?
        private var metricsBeforeMutation: SurfaceStoreMetrics?
        private var fullRectangle: PixelRect?

        func setUp(bitmap: RawBitmap) async throws {
            await tearDown()
            let store = SurfaceStore(backingPolicy: .automatic)
            do {
                try await store.create(
                    id: 2,
                    width: UInt32(bitmap.width),
                    height: UInt32(bitmap.height),
                    format: SurfacePixelFormat.argb8888.rawValue
                )
                try await store.create(
                    id: 3,
                    width: UInt32(bitmap.width),
                    height: UInt32(bitmap.height),
                    format: SurfacePixelFormat.argb8888.rawValue
                )
                let createdMetrics = await store.metrics()
                guard createdMetrics.revisionedBackingEnabled else {
                    throw SpiceBenchError.unsupportedCapability("revisioned-iosurface")
                }
                let fullRectangle = PixelRect(
                    x: 0,
                    y: 0,
                    width: bitmap.width,
                    height: bitmap.height
                )
                // Full uploads establish IOSurface-canonical backing for both
                // surfaces. Bitmap upload has separate metrics, so the AIP-22
                // 1-bulk/0-row gate below uses a full cross-Surface copy.
                _ = try await store.drawCopy(
                    surfaceID: 2,
                    destination: fullRectangle,
                    bitmap: bitmap
                )
                _ = try await store.drawCopy(
                    surfaceID: 3,
                    destination: fullRectangle,
                    bitmap: bitmap
                )
                metricsBeforeMutation = await store.metrics()
                self.fullRectangle = fullRectangle
                self.store = store
            } catch {
                await store.close()
                throw error
            }
        }

        func run() async throws -> Result {
            guard let store, let metricsBeforeMutation, let fullRectangle else {
                throw SpiceBenchWorkloadError.missingState("IOSurface transition")
            }
            // Keep the full cross-Surface copy inside the runner's measured
            // operation. Setup establishes canonical IOSurface backings only.
            _ = try await store.drawCopy(
                surfaceID: 2,
                destination: fullRectangle,
                sourceSurfaceID: 3,
                source: fullRectangle
            )
            let beforeMutation = await store.metrics()
            let revision = try await store.fill(
                surfaceID: 2,
                rectangle: PixelRect(x: 1, y: 1, width: 1, height: 1),
                colorARGB: 0xff11_2233
            )
            return Result(
                revision: revision,
                beforeCopy: metricsBeforeMutation,
                beforeMutation: beforeMutation,
                after: await store.metrics()
            )
        }

        func tearDown() async {
            let store = self.store
            self.store = nil
            metricsBeforeMutation = nil
            fullRectangle = nil
            await store?.close()
        }
    }

    package static func microbenchmarks(
        warmUpIterations: Int = 3,
        measuredIterations: Int = 10
    ) -> [SpiceBenchCase] {
        let fixtures = Fixtures()
        let copyBitsState = CopyBitsBenchmarkState()
        let glzState = GLZBenchmarkState()
        let ioSurfaceState = IOSurfaceBenchmarkState()
        return [
            benchmark(
                id: "wire.contiguous",
                warmUpIterations: warmUpIterations,
                measuredIterations: measuredIterations,
                operation: { try await contiguousWire(fixtures.contiguousWire) }
            ),
            benchmark(
                id: "wire.fragmented",
                warmUpIterations: warmUpIterations,
                measuredIterations: measuredIterations,
                operation: { try await fragmentedWire(fixtures.fragmentedWire) }
            ),
            benchmark(
                id: "region.normalization",
                warmUpIterations: warmUpIterations,
                measuredIterations: measuredIterations,
                operation: {
                    try await normalizeRegion(
                        destination: fixtures.regionDestination,
                        clips: fixtures.regionClips
                    )
                }
            ),
            benchmark(
                id: "copy_bits",
                warmUpIterations: warmUpIterations,
                measuredIterations: measuredIterations,
                setUp: {
                    try await copyBitsState.setUp(
                        bitmap: fixtures.surfaceBitmap,
                        fixture: fixtures.copyBits
                    )
                },
                operation: {
                    try await copyBits(state: copyBitsState, fixture: fixtures.copyBits)
                },
                tearDown: { await copyBitsState.tearDown() }
            ),
            benchmark(
                id: "lz",
                warmUpIterations: warmUpIterations,
                measuredIterations: measuredIterations,
                operation: {
                    try await decodeLZ(
                        decoder: fixtures.lzDecoder,
                        descriptor: fixtures.codecDescriptor,
                        payload: fixtures.lzPayload,
                        overlapReferencePixels: fixtures.overlapReferencePixels
                    )
                }
            ),
            benchmark(
                id: "glz",
                warmUpIterations: warmUpIterations,
                measuredIterations: measuredIterations,
                setUp: { await glzState.setUp() },
                operation: {
                    try await decodeGLZ(
                        state: glzState,
                        descriptor: fixtures.codecDescriptor,
                        payload: fixtures.glzPayload,
                        overlapReferencePixels: fixtures.overlapReferencePixels
                    )
                },
                tearDown: { await glzState.tearDown() }
            ),
            benchmark(
                id: "iosurface.transition",
                warmUpIterations: warmUpIterations,
                measuredIterations: measuredIterations,
                setUp: {
                    try await ioSurfaceState.setUp(bitmap: fixtures.ioSurfaceBitmap)
                },
                operation: { try await transitionIOSurfaceBacking(state: ioSurfaceState) },
                tearDown: { await ioSurfaceState.tearDown() }
            ),
            benchmark(
                id: "advanced_video.sample",
                warmUpIterations: warmUpIterations,
                measuredIterations: measuredIterations,
                operation: {
                    try await advancedVideoObservation(
                        parser: fixtures.videoParser,
                        payload: fixtures.videoPayload
                    )
                }
            ),
        ]
    }

    private static func benchmark(
        id: String,
        warmUpIterations: Int,
        measuredIterations: Int,
        setUp: @escaping @Sendable () async throws -> Void = {},
        operation: @escaping @Sendable () async throws -> SpiceBenchObservation,
        tearDown: @escaping @Sendable () async -> Void = {}
    ) -> SpiceBenchCase {
        SpiceBenchCase(
            id: id,
            warmUpIterations: warmUpIterations,
            measuredIterations: measuredIterations,
            setUp: setUp,
            operation: operation,
            tearDown: tearDown
        )
    }

    private static func contiguousWire(
        _ fixture: WireFixture
    ) async throws -> SpiceBenchObservation {
        var framer = MessageFramer(mode: .mini)
        try framer.append(fixture.wire)
        guard let message = try framer.nextMessage() else {
            throw SpiceBenchWorkloadError.missingOutput("contiguous framed message")
        }
        let diagnostics = framer.diagnostics
        return SpiceBenchObservation(
            checksum: checksum(message.bodySlice),
            exactCounters: [
                "bodyBytes": UInt64(fixture.bodyByteCount),
                "bodyCoalesces": diagnostics.bodyCoalesces,
                "bodyCopyBytes": diagnostics.bodyCopyBytes,
                "queueCompactionBytes": diagnostics.queueCompactionBytes,
            ]
        )
    }

    private static func fragmentedWire(
        _ fixture: FragmentedWireFixture
    ) async throws -> SpiceBenchObservation {
        var framer = MessageFramer(mode: .mini)
        for segment in fixture.segments {
            try framer.append(segment)
        }
        guard let message = try framer.nextMessage() else {
            throw SpiceBenchWorkloadError.missingOutput("fragmented framed message")
        }
        let diagnostics = framer.diagnostics
        return SpiceBenchObservation(
            checksum: checksum(message.bodySlice),
            exactCounters: [
                "bodyBytes": UInt64(fixture.bodyByteCount),
                "bodyCoalesces": diagnostics.bodyCoalesces,
                "bodyCopyBytes": diagnostics.bodyCopyBytes,
                "queueCompactionBytes": diagnostics.queueCompactionBytes,
            ]
        )
    }

    private static func normalizeRegion(
        destination: PixelRect,
        clips: [PixelRect]
    ) async throws -> SpiceBenchObservation {
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: destination,
            clips: clips
        )
        var result: UInt64 = UInt64(region.bandCount) &+ UInt64(region.segmentCount)
        for rectangle in region {
            result = mix(result, UInt64(rectangle.x))
            result = mix(result, UInt64(rectangle.y))
            result = mix(result, UInt64(rectangle.width))
            result = mix(result, UInt64(rectangle.height))
        }
        return SpiceBenchObservation(
            checksum: nonzero(result),
            exactCounters: [
                "inputClips": UInt64(clips.count),
                "normalizedBands": UInt64(region.bandCount),
                "normalizedSegments": UInt64(region.segmentCount),
            ]
        )
    }

    private static func copyBits(
        state: CopyBitsBenchmarkState,
        fixture: CopyBitsFixture
    ) async throws -> SpiceBenchObservation {
        let result = try await state.run(fixture: fixture)
        return SpiceBenchObservation(
            checksum: revisionChecksum(result.revision),
            exactCounters: [
                "mutationTransactions": result.after.mutationTransactions
                    - result.before.mutationTransactions,
                "temporaryCopyBytes": result.after.temporaryCopyBytes
                    - result.before.temporaryCopyBytes,
                "bulkCopyCalls": result.after.bulkCopyCalls - result.before.bulkCopyCalls,
                "rowCopyCalls": result.after.rowCopyCalls - result.before.rowCopyCalls,
            ]
        )
    }

    private static func decodeLZ(
        decoder: SpiceLZDecoder,
        descriptor: SpiceCodecImageDescriptor,
        payload: Data,
        overlapReferencePixels: UInt64
    ) async throws -> SpiceBenchObservation {
        let result = try await decoder.decodeWithDiagnostics(
            descriptor: descriptor,
            payload: payload
        )
        let diagnostics = result.diagnostics
        return SpiceBenchObservation(
            checksum: checksum(result.image.pixelsBGRA),
            exactCounters: [
                "decodedOutputAllocations": diagnostics.decodedOutputAllocations,
                "decodedOutputBytes": diagnostics.decodedOutputBytes,
                "temporaryDecodedBackingAllocations": diagnostics.temporaryDecodedBackingAllocations,
                "temporaryDecodedBackingBytes": diagnostics.temporaryDecodedBackingBytes,
                "referenceBulkCopyCalls": diagnostics.referenceBulkCopyCalls,
                "referenceBulkCopyBytes": diagnostics.referenceBulkCopyBytes,
                "overlapReferencePixels": overlapReferencePixels,
            ]
        )
    }

    private static func decodeGLZ(
        state: GLZBenchmarkState,
        descriptor: SpiceCodecImageDescriptor,
        payload: Data,
        overlapReferencePixels: UInt64
    ) async throws -> SpiceBenchObservation {
        let result = try await state.run(descriptor: descriptor, payload: payload)
        return SpiceBenchObservation(
            checksum: checksum(result.image.pixelsBGRA),
            exactCounters: [
                "dictionaryImages": UInt64(result.diagnostics.dictionaryImages),
                "dictionaryBytes": UInt64(result.diagnostics.dictionaryBytes),
                "pendingDictionaryWaitBytes": UInt64(
                    result.diagnostics.pendingDictionaryWaitBytes
                ),
                "overlapReferencePixels": overlapReferencePixels,
            ]
        )
    }

    private static func transitionIOSurfaceBacking(
        state: IOSurfaceBenchmarkState
    ) async throws -> SpiceBenchObservation {
        let result = try await state.run()
        return SpiceBenchObservation(
            checksum: revisionChecksum(result.revision),
            exactCounters: [
                "cpuMaterializationBytes": result.after.cpuMaterializationBytes
                    - result.beforeMutation.cpuMaterializationBytes,
                "cpuMaterializations": result.after.cpuMaterializations
                    - result.beforeMutation.cpuMaterializations,
                "revisionedBackingEnabled": 1,
                "bulkCopyCalls": result.beforeMutation.bulkCopyCalls
                    - result.beforeCopy.bulkCopyCalls,
                "rowCopyCalls": result.beforeMutation.rowCopyCalls
                    - result.beforeCopy.rowCopyCalls,
                "directIOSurfaceWriteBytes": result.after.directIOSurfaceWriteBytes
                    - result.beforeMutation.directIOSurfaceWriteBytes,
            ]
        )
    }

    package static func advancedVideoObservation(
        parser: SpiceAnnexBParser,
        payload: Data
    ) async throws -> SpiceBenchObservation {
        let result = try parser.parseWithDiagnostics(codec: .h264, payload: payload)
        let diagnostics = result.diagnostics
        return SpiceBenchObservation(
            checksum: checksum(result.accessUnit.sampleData),
            exactCounters: [
                "scanPassCount": UInt64(diagnostics.scanPassCount),
                "inputCopyBytes": UInt64(diagnostics.inputCopyBytes),
                "nalPayloadMaterializations": UInt64(diagnostics.nalPayloadMaterializations),
                "nalPayloadCopyBytes": UInt64(diagnostics.nalPayloadCopyBytes),
                "avccSampleAllocations": UInt64(diagnostics.avccSampleAllocations),
                "avccSampleBytes": UInt64(diagnostics.avccSampleBytes),
                "avccPayloadWriteBytes": UInt64(diagnostics.samplePayloadCopyBytes),
                "samplePayloadCopyBytes": UInt64(
                    diagnostics.additionalSamplePayloadCopyBytes
                ),
                "nalUnitCount": UInt64(diagnostics.nalUnitCount),
            ]
        )
    }

    private static func miniMessage(type: UInt16, body: Data) -> Data {
        var wire = Data()
        appendLittleEndian(type, to: &wire)
        appendLittleEndian(UInt32(body.count), to: &wire)
        wire.append(body)
        return wire
    }

    private static func lzRGBPayload(width: Int, height: Int) -> Data {
        var payload = Data()
        appendBigEndian(UInt32(0x2020_5a4c), to: &payload)
        appendBigEndian(UInt32(0x0001_0001), to: &payload)
        appendBigEndian(UInt32(7), to: &payload)
        appendBigEndian(UInt32(width), to: &payload)
        appendBigEndian(UInt32(height), to: &payload)
        appendBigEndian(UInt32(width * 3), to: &payload)
        appendBigEndian(UInt32(1), to: &payload)
        payload.append(contentsOf: [0, 0x12, 0x34, 0x56])
        appendLZDistanceOneReference(length: width * height - 1, to: &payload)
        return payload
    }

    private static func glzRGBPayload(width: Int, height: Int) -> Data {
        var payload = Data([0x20, 0x20, 0x5a, 0x4c, 0, 1, 0, 1, 0x18])
        appendBigEndian(UInt32(width), to: &payload)
        appendBigEndian(UInt32(height), to: &payload)
        appendBigEndian(UInt32(width * 4), to: &payload)
        appendBigEndian(UInt64(0), to: &payload)
        appendBigEndian(UInt32(0), to: &payload)
        // GLZ type 8 has a 4-byte decoded stride but encodes only B/G/R. One
        // literal followed by a long distance-1 reference exercises bounded
        // overlap doubling rather than an all-literal parse.
        payload.append(contentsOf: [0, 0x12, 0x34, 0x56])
        appendGLZDistanceOneReference(length: width * height - 1, to: &payload)
        return payload
    }

    private static func appendLZDistanceOneReference(length: Int, to payload: inout Data) {
        guard length > 0 else { return }
        let encodedLength = length - 1
        if encodedLength < 6 {
            payload.append(UInt8((encodedLength + 1) << 5))
        } else {
            payload.append(0xe0)
            appendLengthExtension(encodedLength - 6, to: &payload)
        }
        payload.append(0)
    }

    private static func appendGLZDistanceOneReference(length: Int, to payload: inout Data) {
        guard length >= 7 else { return }
        payload.append(0xe0)
        appendLengthExtension(length - 7, to: &payload)
        payload.append(contentsOf: [0, 0])
    }

    private static func appendLengthExtension(_ length: Int, to payload: inout Data) {
        var remainder = max(0, length)
        while remainder >= 255 {
            payload.append(255)
            remainder -= 255
        }
        payload.append(UInt8(remainder))
    }

    private static func deterministicBytes(count: Int) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    /// A fixed-size anti-DCE sample. It includes the byte count and evenly
    /// spaced bytes without turning checksum time into a second full decode.
    private static func checksum(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return sampledChecksum(count: bytes.count) { bytes[$0] }
        }
    }

    /// Samples a borrowed wire span directly. In particular, this never calls
    /// `WireSlice.data`, whose sliced boundary intentionally materializes.
    private static func checksum(_ slice: WireSlice) -> UInt64 {
        slice.withSpan { bytes in
            sampledChecksum(count: bytes.count) { bytes[$0] }
        }
    }

    private static func sampledChecksum(
        count: Int,
        byteAt: (Int) -> UInt8
    ) -> UInt64 {
        var result = mix(0xcbf2_9ce4_8422_2325, UInt64(count))
        let sampleCount = min(64, count)
        guard sampleCount > 0 else { return nonzero(result) }
        for sample in 0 ..< sampleCount {
            let index = evenlySpacedIndex(
                sample: sample,
                sampleCount: sampleCount,
                elementCount: count
            )
            result = mix(result, UInt64(index))
            result = mix(result, UInt64(byteAt(index)))
        }
        return nonzero(result)
    }

    private static func evenlySpacedIndex(
        sample: Int,
        sampleCount: Int,
        elementCount: Int
    ) -> Int {
        guard sampleCount > 1 else { return 0 }
        let lastIndex = elementCount - 1
        let intervals = sampleCount - 1
        // Splitting quotient and remainder avoids `lastIndex * sample`
        // overflow even if a future benchmark accepts a near-Int.max owner.
        return (lastIndex / intervals) * sample
            + ((lastIndex % intervals) * sample) / intervals
    }

    private static func mix(_ partial: UInt64, _ value: UInt64) -> UInt64 {
        (partial ^ value) &* 0x0000_0100_0000_01b3
    }

    private static func nonzero(_ value: UInt64) -> UInt64 {
        value == 0 ? 1 : value
    }

    private static func revisionChecksum(_ revision: SurfaceRevision) -> UInt64 {
        nonzero(
            mix(
                mix(UInt64(revision.surfaceID), revision.lifecycleGeneration),
                revision.revision
            )
        )
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

private enum SpiceBenchWorkloadError: Error {
    case missingOutput(String)
    case missingState(String)
}
