import Darwin
import Dispatch
import Foundation
import SpiceIOSurface
import SpiceTransport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceRenderer
@testable import SpiceWire

@Suite("Opt-in local CPU display hot-path benchmark", .serialized)
struct CPUHotPathBenchmarkTests {
    private static let enableEnvironment = "SWIFTSPICE_CPU_HOTPATH_BENCHMARK"
    private static let backendEnvironment = "SWIFTSPICE_CPU_HOTPATH_BACKEND"
    private static let resolutionEnvironment = "SWIFTSPICE_CPU_HOTPATH_RESOLUTION"
    private static let frameCountEnvironment = "SWIFTSPICE_CPU_HOTPATH_FRAMES"
    private static let diagnosticsEnvironment = "SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS"

    private static let commandsPerFrame = 57
    private static let bitmapWidth = 32
    private static let bitmapHeight = 25
    private static let bitmapPayloadBytes = bitmapWidth * bitmapHeight * 4
    private static let publicationIntervalMilliseconds: Int64 = 16
    private static let diagnosticsCommandSamplePeriod: UInt64 = 64
    private static let defaultFrameCount = 1_500

    /// This test is deliberately inert in normal `swift test` runs. Use the
    /// environment variables documented in Benchmarks/CPU_HOT_PATH_LOCAL.md.
    @Test func deterministicMiniHeaderDisplayPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[Self.enableEnvironment] == "1" else {
            return
        }

        let backend = try parseBackend(environment[Self.backendEnvironment])
        let resolution = try parseResolution(environment[Self.resolutionEnvironment])
        let frameCount = try parseFrameCount(environment[Self.frameCountEnvironment])
        let diagnosticsEnabled = environment[Self.diagnosticsEnvironment] == "1"
        let diagnosticsMode: RenderDiagnosticsMode = diagnosticsEnabled
            ? .sampled(commandPeriod: Self.diagnosticsCommandSamplePeriod)
            : .disabled
        let expectedCommandCount = frameCount * Self.commandsPerFrame

        // Fixture construction is intentionally outside the measured region.
        // One 57-command frame is replayed by the paced transport, preserving
        // the real MessageFramer copies without allocating a 280+ MiB fixture.
        let surfaceCreate = try encodeMini(SpiceMsgDisplaySurfaceCreate(
            surfaceID: 1,
            width: UInt32(resolution.width),
            height: UInt32(resolution.height),
            format: 32,
            flags: 1
        ))
        let frameWire = makeFrameWire(resolution: resolution)
        let inputDrainedGate = CPUHotPathCompletionGate()
        let finalFrameGate = CPUHotPathCompletionGate()
        let transportFinishGate = CPUHotPathCompletionGate()
        let transport = CPUHotPathPacedTransport(
            prefix: surfaceCreate,
            frameWire: frameWire,
            frameCount: frameCount,
            frameIntervalMilliseconds: Self.publicationIntervalMilliseconds,
            inputDrainedGate: inputDrainedGate,
            finishGate: transportFinishGate,
            finishTimeout: .seconds(15)
        )
        try await transport.connect()

        let disabledLegacyPool = IOSurfaceFramePool(
            limits: .init(maximumFrames: 0, maximumBytes: 0)
        )
        let store: SurfaceStore
        switch backend {
        case .dataOnly:
            store = SurfaceStore(
                framePool: disabledLegacyPool,
                backingPolicy: .dataOnly,
                diagnosticsMode: diagnosticsMode
            )
        case .cpuIOSurface:
            guard let revisionedPool = RevisionedIOSurfacePool.makeIfSupported() else {
                throw CPUHotPathBenchmarkError.revisionedIOSurfaceUnavailable
            }
            store = SurfaceStore(
                framePool: disabledLegacyPool,
                backingPolicy: .revisionedIOSurface(revisionedPool),
                diagnosticsMode: diagnosticsMode
            )
        }

        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini,
                diagnosticsMode: diagnosticsMode
            ),
            surfaces: store,
            framePublicationInterval: .milliseconds(Self.publicationIntervalMilliseconds),
            diagnosticsMode: diagnosticsMode
        )
        let frameSink = CPUHotPathFrameSink(
            surfaceID: 1,
            expectedRevision: UInt64(expectedCommandCount),
            finalFrameGate: finalFrameGate
        )

        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = processCPUNanoseconds()
        let runTask = Task { () -> Result<Void, any Error> in
            do {
                try await channel.run { event in
                    if case let .frame(frame) = event {
                        await frameSink.consume(frame)
                    }
                }
                await inputDrainedGate.complete()
                await finalFrameGate.complete()
                return .success(())
            } catch let error {
                await inputDrainedGate.complete()
                await finalFrameGate.complete()
                return .failure(error)
            }
        }

        let inputTimeout = Duration.milliseconds(
            Int64(frameCount) * Self.publicationIntervalMilliseconds + 5_000
        )
        guard await inputDrainedGate.wait(timeout: inputTimeout) else {
            await transportFinishGate.complete()
            await transport.close()
            runTask.cancel()
            _ = await runTask.value
            throw CPUHotPathBenchmarkError.inputDrainTimeout
        }
        let receivedFinalFrame = await finalFrameGate.wait(timeout: .seconds(5))
        var sinkMetrics = await frameSink.metrics()
        guard receivedFinalFrame,
              sinkMetrics.lastPublishedRevision == UInt64(expectedCommandCount)
        else {
            await transportFinishGate.complete()
            let runResult = await runTask.value
            if case let .failure(error) = runResult {
                guard let channelError = error as? ChannelError,
                      channelError == .transport(.connectionClosed)
                else {
                    throw error
                }
            }
            throw CPUHotPathBenchmarkError.publisherCompletionTimeout
        }

        // `consume` runs inside DisplayFramePublisher.emit, before the
        // publisher increments emittedFrames. An actor hop to publisher.metrics
        // may legally re-enter during that await, so keep hopping until the
        // emitted counter catches the sink. This creates a strict happens-before
        // without a fixed sleep/yield and keeps EOF from cancelling the flush.
        let drainDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        var diagnostics = await channel.diagnosticsSnapshot()
        while diagnostics.publisher.emittedFrames != sinkMetrics.frames {
            guard ContinuousClock.now < drainDeadline else {
                await transportFinishGate.complete()
                let runResult = await runTask.value
                if case let .failure(error) = runResult {
                    guard let channelError = error as? ChannelError,
                          channelError == .transport(.connectionClosed)
                    else {
                        throw error
                    }
                }
                throw CPUHotPathBenchmarkError.publisherCompletionTimeout
            }
            diagnostics = await channel.diagnosticsSnapshot()
            sinkMetrics = await frameSink.metrics()
        }

        await transportFinishGate.complete()
        let runResult = await runTask.value
        guard case let .failure(runError) = runResult else {
            throw CPUHotPathBenchmarkError.unexpectedTransportCompletion
        }
        guard let channelError = runError as? ChannelError else {
            throw runError
        }
        guard channelError == .transport(.connectionClosed) else {
            throw channelError
        }
        let cpuEnd = processCPUNanoseconds()
        let wallEnd = DispatchTime.now().uptimeNanoseconds

        let currentRSS = currentResidentBytes()
        let peakRSS = peakResidentBytes()

        try #require(currentRSS > 0)
        try #require(peakRSS >= currentRSS)
        try #require(diagnostics.publisher.submissions == UInt64(expectedCommandCount))
        try #require(diagnostics.publisher.emittedFrames == sinkMetrics.frames)
        try #require(diagnostics.publisher.emittedFrames > 0)
        try #require(diagnostics.publisher.pendingSurfaces == 0)
        try #require(diagnostics.publisher.snapshotAttempts == diagnostics.surfaces.snapshots)
        try #require(diagnostics.publisher.staleSnapshots == 0)
        try #require(diagnostics.publisher.pendingEvictions == 0)
        try #require(sinkMetrics.lastPublishedRevision == UInt64(expectedCommandCount))
        try #require(diagnostics.surfaces.damageOperations == UInt64(expectedCommandCount))
        try #require(
            diagnostics.surfaces.damageBytes
                == UInt64(expectedCommandCount * Self.bitmapPayloadBytes)
        )
        if diagnosticsEnabled {
            let expectedBitmapSamples = UInt64(expectedCommandCount)
                / Self.diagnosticsCommandSamplePeriod
            let expectedMessageSamples = UInt64(expectedCommandCount + 1)
                / Self.diagnosticsCommandSamplePeriod
            try #require(
                diagnostics.connection.framerNextTiming.samplePeriod
                    == Self.diagnosticsCommandSamplePeriod
            )
            try #require(
                diagnostics.connection.framerNextTiming.samples
                    >= expectedMessageSamples
            )
            try #require(
                diagnostics.connection.framerAppendTiming.samplePeriod
                    == Self.diagnosticsCommandSamplePeriod
            )
            if frameCount >= Int(Self.diagnosticsCommandSamplePeriod) {
                try #require(diagnostics.connection.framerAppendTiming.samples > 0)
            }
            try #require(
                diagnostics.messageHandlingTiming.samplePeriod
                    == Self.diagnosticsCommandSamplePeriod
            )
            try #require(diagnostics.messageHandlingTiming.samples == expectedMessageSamples)
            try #require(
                diagnostics.messageDecodeTiming.samplePeriod
                    == Self.diagnosticsCommandSamplePeriod
            )
            try #require(diagnostics.messageDecodeTiming.samples == expectedMessageSamples)
            try #require(
                diagnostics.bitmapSurfaceStoreRoundTripTiming.samplePeriod
                    == Self.diagnosticsCommandSamplePeriod
            )
            try #require(
                diagnostics.bitmapSurfaceStoreRoundTripTiming.samples
                    == expectedBitmapSamples
            )
            try #require(
                diagnostics.publisherSubmitRoundTripTiming.samplePeriod
                    == Self.diagnosticsCommandSamplePeriod
            )
            try #require(
                diagnostics.publisherSubmitRoundTripTiming.samples
                    == expectedBitmapSamples
            )
            try #require(diagnostics.publisher.frameEmitTiming.samplePeriod == 1)
            try #require(
                diagnostics.publisher.frameEmitTiming.samples
                    == diagnostics.publisher.emittedFrames
            )
            try #require(
                diagnostics.surfaces.bitmapValidationTiming.samplePeriod
                    == Self.diagnosticsCommandSamplePeriod
            )
            try #require(
                diagnostics.surfaces.bitmapValidationTiming.samples
                    == expectedBitmapSamples
            )
            try #require(
                diagnostics.surfaces.bitmapMutationTiming.samples
                    == expectedBitmapSamples
            )
            try #require(
                diagnostics.surfaces.bitmapDamageJournalTiming.samples
                    == expectedBitmapSamples
            )
            try #require(diagnostics.surfaces.snapshotCheckoutTiming.samplePeriod == 1)
            try #require(diagnostics.surfaces.snapshotDamagePlanTiming.samplePeriod == 1)
            try #require(diagnostics.surfaces.snapshotCPUCopyTiming.samplePeriod == 1)
            try #require(diagnostics.surfaces.snapshotFinishTiming.samplePeriod == 1)
        } else {
            try #require(diagnostics.connection.framerNextTiming == RenderPhaseMetrics())
            try #require(diagnostics.connection.framerAppendTiming == RenderPhaseMetrics())
            try #require(diagnostics.messageHandlingTiming == RenderPhaseMetrics())
            try #require(diagnostics.messageDecodeTiming == RenderPhaseMetrics())
            try #require(
                diagnostics.bitmapSurfaceStoreRoundTripTiming == RenderPhaseMetrics()
            )
            try #require(
                diagnostics.publisherSubmitRoundTripTiming == RenderPhaseMetrics()
            )
            try #require(diagnostics.publisher.frameEmitTiming == RenderPhaseMetrics())
            try #require(diagnostics.surfaces.bitmapValidationTiming.samplePeriod == nil)
            try #require(diagnostics.surfaces.bitmapValidationTiming.samples == 0)
            try #require(diagnostics.surfaces.bitmapMutationTiming.samples == 0)
            try #require(diagnostics.surfaces.bitmapDamageJournalTiming.samples == 0)
            try #require(diagnostics.surfaces.snapshotCheckoutTiming.samplePeriod == nil)
            try #require(diagnostics.surfaces.snapshotCheckoutTiming.samples == 0)
            try #require(diagnostics.surfaces.snapshotDamagePlanTiming.samples == 0)
            try #require(diagnostics.surfaces.snapshotCPUCopyTiming.samples == 0)
            try #require(diagnostics.surfaces.snapshotFinishTiming.samples == 0)
        }

        switch backend {
        case .dataOnly:
            try #require(!diagnostics.surfaces.revisionedBackingEnabled)
            try #require(diagnostics.surfaces.inFlightLeases == 0)
            try #require(
                diagnostics.surfaces.dataBackendSnapshots
                    == diagnostics.surfaces.snapshots
            )
            try #require(diagnostics.surfaces.revisionedSnapshotUploads == 0)
            try #require(
                diagnostics.surfaces.poolExhaustions
                    == diagnostics.surfaces.snapshots
            )
            try #require(diagnostics.surfaces.damageRectanglesBeforeMerge == 0)
            try #require(diagnostics.surfaces.damageRectanglesAfterMerge == 0)
            try #require(diagnostics.surfaces.fullDamageByCount == 0)
            try #require(diagnostics.surfaces.fullDamageByArea == 0)
            try #require(diagnostics.surfaces.fullDamageByExplicit == 0)
            try #require(diagnostics.surfaces.fullDamageBySurfaceInitialization == 0)
            try #require(diagnostics.surfaces.fullDamageByNewSlot == 0)
            try #require(diagnostics.surfaces.fullDamageByHistoryGap == 0)
            if diagnosticsEnabled {
                try #require(diagnostics.surfaces.snapshotCheckoutTiming.samples == 0)
                try #require(diagnostics.surfaces.snapshotDamagePlanTiming.samples == 0)
                try #require(diagnostics.surfaces.snapshotCPUCopyTiming.samples == 0)
                try #require(diagnostics.surfaces.snapshotFinishTiming.samples == 0)
            }
        case .cpuIOSurface:
            try #require(diagnostics.surfaces.revisionedBackingEnabled)
            try #require(diagnostics.surfaces.inFlightLeases == 1)
            try #require(
                diagnostics.surfaces.revisionedSnapshotUploads
                    &+ diagnostics.surfaces.revisionedSnapshotReuses
                    == diagnostics.surfaces.snapshots
            )
            try #require(
                diagnostics.surfaces.revisionedAllocatedFrames
                    >= min(2, frameCount)
            )
            try #require(diagnostics.surfaces.dataBackendSnapshots == 0)
            try #require(diagnostics.surfaces.revisionedSnapshotFallbacks == 0)
            try #require(diagnostics.surfaces.unifiedBackingDisables == 0)
            try #require(diagnostics.surfaces.cpuMaterializations == 0)
            try #require(diagnostics.surfaces.poolExhaustions == 0)
            try #require(diagnostics.surfaces.gpuErrors == 0)
            if diagnosticsEnabled {
                let uploads = diagnostics.surfaces.revisionedSnapshotUploads
                try #require(
                    diagnostics.surfaces.snapshotCheckoutTiming.samples == uploads
                )
                try #require(
                    diagnostics.surfaces.snapshotDamagePlanTiming.samples == uploads
                )
                try #require(
                    diagnostics.surfaces.snapshotCPUCopyTiming.samples == uploads
                )
                try #require(
                    diagnostics.surfaces.snapshotFinishTiming.samples == uploads
                )
            }
            let fullDamagePlans = diagnostics.surfaces.fullDamageByCount
                &+ diagnostics.surfaces.fullDamageByArea
                &+ diagnostics.surfaces.fullDamageByExplicit
                &+ diagnostics.surfaces.fullDamageBySurfaceInitialization
                &+ diagnostics.surfaces.fullDamageByNewSlot
                &+ diagnostics.surfaces.fullDamageByHistoryGap
            try #require(fullDamagePlans <= diagnostics.surfaces.revisionedSnapshotUploads)
            if diagnostics.surfaces.snapshotCatchUpCPUCopyBytes == 0 {
                try #require(diagnostics.surfaces.damageRectanglesBeforeMerge == 0)
                try #require(diagnostics.surfaces.damageRectanglesAfterMerge == 0)
                try #require(fullDamagePlans == 0)
            } else {
                try #require(diagnostics.surfaces.damageRectanglesAfterMerge > 0)
                try #require(
                    diagnostics.surfaces.damageRectanglesAfterMerge
                        <= diagnostics.surfaces.damageRectanglesBeforeMerge
                            &+ fullDamagePlans
                )
            }
        }

        // Correctness is checked after the timed/metric snapshot so this
        // explicit readback cannot inflate publication or materialization data.
        let finalSnapshot = try await channel.snapshot(surfaceID: 1)
        try #require(finalSnapshot.revision == UInt64(expectedCommandCount))
        switch backend {
        case .dataOnly:
            try #require(finalSnapshot.ioSurfaceFrame == nil)
        case .cpuIOSurface:
            try #require(finalSnapshot.ioSurfaceFrame != nil)
        }
        try #require(pixel(finalSnapshot, x: 0, y: 0) == [1, 0x22, 0x33, 0xff])
        await channel.close()

        let wallNanoseconds = wallEnd >= wallStart ? wallEnd - wallStart : 0
        let cpuNanoseconds = cpuEnd >= cpuStart ? cpuEnd - cpuStart : 0
        let result = CPUHotPathBenchmarkResult(
            backend: backend.rawValue,
            resolution: resolution.rawValue,
            width: resolution.width,
            height: resolution.height,
            frames: frameCount,
            commands: expectedCommandCount,
            diagnosticsEnabled: diagnosticsEnabled,
            commandsPerFrame: Self.commandsPerFrame,
            bitmapWidth: Self.bitmapWidth,
            bitmapHeight: Self.bitmapHeight,
            bitmapPayloadBytes: Self.bitmapPayloadBytes,
            publisherIntervalNanoseconds: UInt64(
                Self.publicationIntervalMilliseconds * 1_000_000
            ),
            wallNanoseconds: wallNanoseconds,
            processCPUNanoseconds: cpuNanoseconds,
            cpuNanosecondsPerFrame: cpuNanoseconds / UInt64(frameCount),
            cpuNanosecondsPerCommand: cpuNanoseconds / UInt64(expectedCommandCount),
            cpuNanosecondsPerPublishedFrame:
                cpuNanoseconds / diagnostics.publisher.emittedFrames,
            residentBytes: currentRSS,
            peakResidentBytes: peakRSS,
            publishedFPSMilli: wallNanoseconds == 0
                ? 0
                : sinkMetrics.frames * 1_000_000_000_000 / wallNanoseconds,
            publisherP95IntervalNanoseconds: sinkMetrics.p95IntervalNanoseconds,
            lastPublishedRevision: sinkMetrics.lastPublishedRevision,
            publisherSubmissions: diagnostics.publisher.submissions,
            publisherSnapshotAttempts: diagnostics.publisher.snapshotAttempts,
            publisherEmittedFrames: diagnostics.publisher.emittedFrames,
            publisherStaleSnapshots: diagnostics.publisher.staleSnapshots,
            publisherPendingEvictions: diagnostics.publisher.pendingEvictions,
            publisherPendingSurfaces: diagnostics.publisher.pendingSurfaces,
            damageOperations: diagnostics.surfaces.damageOperations,
            damageBytes: diagnostics.surfaces.damageBytes,
            damageRectanglesBeforeMerge:
                diagnostics.surfaces.damageRectanglesBeforeMerge,
            damageRectanglesAfterMerge:
                diagnostics.surfaces.damageRectanglesAfterMerge,
            fullDamageByCount: diagnostics.surfaces.fullDamageByCount,
            fullDamageByArea: diagnostics.surfaces.fullDamageByArea,
            fullDamageByExplicit: diagnostics.surfaces.fullDamageByExplicit,
            fullDamageBySurfaceInitialization:
                diagnostics.surfaces.fullDamageBySurfaceInitialization,
            fullDamageByNewSlot: diagnostics.surfaces.fullDamageByNewSlot,
            fullDamageByHistoryGap: diagnostics.surfaces.fullDamageByHistoryGap,
            snapshots: diagnostics.surfaces.snapshots,
            fullFrameCopyBytes: diagnostics.surfaces.fullFrameCopyBytes,
            partialFrameCopyBytes: diagnostics.surfaces.partialFrameCopyBytes,
            snapshotCatchUpCPUCopyBytes:
                diagnostics.surfaces.snapshotCatchUpCPUCopyBytes,
            cpuMaterializations: diagnostics.surfaces.cpuMaterializations,
            cpuMaterializationBytes: diagnostics.surfaces.cpuMaterializationBytes,
            poolExhaustions: diagnostics.surfaces.poolExhaustions,
            inFlightLeases: diagnostics.surfaces.inFlightLeases,
            revisionedBackingEnabled: diagnostics.surfaces.revisionedBackingEnabled,
            revisionedAllocatedFrames: diagnostics.surfaces.revisionedAllocatedFrames,
            revisionedAllocatedBytes: diagnostics.surfaces.revisionedAllocatedBytes,
            recommendedMaximumWorkingSetSize:
                diagnostics.surfaces.recommendedMaximumWorkingSetSize,
            currentMetalAllocatedSize: diagnostics.surfaces.currentMetalAllocatedSize,
            gpuCopyBytes: diagnostics.surfaces.gpuCopyBytes,
            gpuErrors: diagnostics.surfaces.gpuErrors,
            compositorErrors: diagnostics.surfaces.compositorErrors,
            nativeVideoFrames: diagnostics.surfaces.nativeVideoFrames,
            nativeVideoFallbacks: diagnostics.surfaces.nativeVideoFallbacks,
            revisionedSnapshotReuses: diagnostics.surfaces.revisionedSnapshotReuses,
            revisionedSnapshotUploads: diagnostics.surfaces.revisionedSnapshotUploads,
            dataBackendSnapshots: diagnostics.surfaces.dataBackendSnapshots,
            revisionedSnapshotFallbacks:
                diagnostics.surfaces.revisionedSnapshotFallbacks,
            unifiedBackingDisables: diagnostics.surfaces.unifiedBackingDisables,
            wireFramerNextSamplePeriod:
                diagnostics.connection.framerNextTiming.samplePeriod ?? 0,
            wireFramerNextSamples:
                diagnostics.connection.framerNextTiming.samples,
            wireFramerNextSampledNanoseconds:
                diagnostics.connection.framerNextTiming.sampledNanoseconds,
            wireFramerAppendSamplePeriod:
                diagnostics.connection.framerAppendTiming.samplePeriod ?? 0,
            wireFramerAppendSamples:
                diagnostics.connection.framerAppendTiming.samples,
            wireFramerAppendSampledNanoseconds:
                diagnostics.connection.framerAppendTiming.sampledNanoseconds,
            displayMessageHandlingSamplePeriod:
                diagnostics.messageHandlingTiming.samplePeriod ?? 0,
            displayMessageHandlingSamples:
                diagnostics.messageHandlingTiming.samples,
            displayMessageHandlingSampledNanoseconds:
                diagnostics.messageHandlingTiming.sampledNanoseconds,
            displayMessageDecodeSamplePeriod:
                diagnostics.messageDecodeTiming.samplePeriod ?? 0,
            displayMessageDecodeSamples:
                diagnostics.messageDecodeTiming.samples,
            displayMessageDecodeSampledNanoseconds:
                diagnostics.messageDecodeTiming.sampledNanoseconds,
            bitmapSurfaceStoreRoundTripSamplePeriod:
                diagnostics.bitmapSurfaceStoreRoundTripTiming.samplePeriod ?? 0,
            bitmapSurfaceStoreRoundTripSamples:
                diagnostics.bitmapSurfaceStoreRoundTripTiming.samples,
            bitmapSurfaceStoreRoundTripSampledNanoseconds:
                diagnostics.bitmapSurfaceStoreRoundTripTiming.sampledNanoseconds,
            publisherSubmitRoundTripSamplePeriod:
                diagnostics.publisherSubmitRoundTripTiming.samplePeriod ?? 0,
            publisherSubmitRoundTripSamples:
                diagnostics.publisherSubmitRoundTripTiming.samples,
            publisherSubmitRoundTripSampledNanoseconds:
                diagnostics.publisherSubmitRoundTripTiming.sampledNanoseconds,
            frameEmitSamplePeriod:
                diagnostics.publisher.frameEmitTiming.samplePeriod ?? 0,
            frameEmitSamples: diagnostics.publisher.frameEmitTiming.samples,
            frameEmitSampledNanoseconds:
                diagnostics.publisher.frameEmitTiming.sampledNanoseconds,
            bitmapValidationSamplePeriod:
                diagnostics.surfaces.bitmapValidationTiming.samplePeriod ?? 0,
            bitmapValidationSamples:
                diagnostics.surfaces.bitmapValidationTiming.samples,
            bitmapValidationSampledNanoseconds:
                diagnostics.surfaces.bitmapValidationTiming.sampledNanoseconds,
            bitmapMutationSamplePeriod:
                diagnostics.surfaces.bitmapMutationTiming.samplePeriod ?? 0,
            bitmapMutationSamples:
                diagnostics.surfaces.bitmapMutationTiming.samples,
            bitmapMutationSampledNanoseconds:
                diagnostics.surfaces.bitmapMutationTiming.sampledNanoseconds,
            bitmapDamageJournalSamplePeriod:
                diagnostics.surfaces.bitmapDamageJournalTiming.samplePeriod ?? 0,
            bitmapDamageJournalSamples:
                diagnostics.surfaces.bitmapDamageJournalTiming.samples,
            bitmapDamageJournalSampledNanoseconds:
                diagnostics.surfaces.bitmapDamageJournalTiming.sampledNanoseconds,
            snapshotCheckoutSamplePeriod:
                diagnostics.surfaces.snapshotCheckoutTiming.samplePeriod ?? 0,
            snapshotCheckoutSamples:
                diagnostics.surfaces.snapshotCheckoutTiming.samples,
            snapshotCheckoutSampledNanoseconds:
                diagnostics.surfaces.snapshotCheckoutTiming.sampledNanoseconds,
            snapshotDamagePlanSamplePeriod:
                diagnostics.surfaces.snapshotDamagePlanTiming.samplePeriod ?? 0,
            snapshotDamagePlanSamples:
                diagnostics.surfaces.snapshotDamagePlanTiming.samples,
            snapshotDamagePlanSampledNanoseconds:
                diagnostics.surfaces.snapshotDamagePlanTiming.sampledNanoseconds,
            snapshotCPUCopySamplePeriod:
                diagnostics.surfaces.snapshotCPUCopyTiming.samplePeriod ?? 0,
            snapshotCPUCopySamples:
                diagnostics.surfaces.snapshotCPUCopyTiming.samples,
            snapshotCPUCopySampledNanoseconds:
                diagnostics.surfaces.snapshotCPUCopyTiming.sampledNanoseconds,
            snapshotFinishSamplePeriod:
                diagnostics.surfaces.snapshotFinishTiming.samplePeriod ?? 0,
            snapshotFinishSamples:
                diagnostics.surfaces.snapshotFinishTiming.samples,
            snapshotFinishSampledNanoseconds:
                diagnostics.surfaces.snapshotFinishTiming.sampledNanoseconds
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(result)
        print(String(decoding: json, as: UTF8.self))
    }

    private func parseBackend(_ value: String?) throws -> CPUHotPathBackend {
        switch value ?? CPUHotPathBackend.cpuIOSurface.rawValue {
        case "data-only", "data":
            return .dataOnly
        case "cpu-iosurface", "revisioned-iosurface", "revisioned":
            return .cpuIOSurface
        case let value:
            throw CPUHotPathBenchmarkError.invalidBackend(value)
        }
    }

    private func parseResolution(_ value: String?) throws -> CPUHotPathResolution {
        switch value ?? CPUHotPathResolution.p720.rawValue {
        case "720p", "1280x720":
            return .p720
        case "4k", "3840x2160":
            return .p4K
        case let value:
            throw CPUHotPathBenchmarkError.invalidResolution(value)
        }
    }

    private func parseFrameCount(_ value: String?) throws -> Int {
        guard let value else {
            return Self.defaultFrameCount
        }
        guard let frameCount = Int(value), (1...10_000).contains(frameCount) else {
            throw CPUHotPathBenchmarkError.invalidFrameCount(value)
        }
        return frameCount
    }

    private func makeFrameWire(resolution: CPUHotPathResolution) -> Data {
        let columns = resolution.width / Self.bitmapWidth
        let rows = resolution.height / Self.bitmapHeight
        let slotCount = columns * rows
        precondition(columns > 0 && rows > 0)

        var frame = Data()
        frame.reserveCapacity(Self.commandsPerFrame * (Self.bitmapPayloadBytes + 128))
        for commandIndex in 0..<Self.commandsPerFrame {
            // 37 is coprime with both supported tile counts, spreading the 57
            // rectangles without introducing random fixture state.
            let slot = commandIndex * 37 % slotCount
            let x = slot % columns * Self.bitmapWidth
            let y = slot / columns * Self.bitmapHeight
            let payload = makeBitmapPayload(seed: UInt8(commandIndex + 1))
            let body = drawCopyBody(
                destinationX: x,
                destinationY: y,
                descriptorID: UInt64(commandIndex + 1),
                payload: payload
            )
            frame.append(encodeMini(id: 304, body: body))
        }
        return frame
    }

    private func makeBitmapPayload(seed: UInt8) -> Data {
        var payload = Data(count: Self.bitmapPayloadBytes)
        payload.withUnsafeMutableBytes { bytes in
            let value = UInt32(seed) | UInt32(0x22) << 8 | UInt32(0x33) << 16
            for pixelIndex in 0..<(Self.bitmapWidth * Self.bitmapHeight) {
                bytes.storeBytes(
                    of: value.littleEndian,
                    toByteOffset: pixelIndex * 4,
                    as: UInt32.self
                )
            }
        }
        return payload
    }

    private func drawCopyBody(
        destinationX: Int,
        destinationY: Int,
        descriptorID: UInt64,
        payload: Data
    ) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(1)
        writeRect(
            to: &writer,
            top: destinationY,
            left: destinationX,
            bottom: destinationY + Self.bitmapHeight,
            right: destinationX + Self.bitmapWidth
        )
        writer.writeUInt8(0) // SPICE_CLIP_TYPE_NONE

        let imageOffset = UInt32(writer.data.count + 36)
        writer.writeUInt32LE(imageOffset)
        writeRect(
            to: &writer,
            top: 0,
            left: 0,
            bottom: Self.bitmapHeight,
            right: Self.bitmapWidth
        )
        writer.writeUInt16LE(0x08) // SPICE_ROPD_OP_PUT
        writer.writeUInt8(0) // interpolation is irrelevant without scaling
        writer.writeUInt8(0) // empty mask flags
        writer.writeInt32LE(0)
        writer.writeInt32LE(0)
        writer.writeUInt32LE(0) // no mask image

        writer.writeUInt64LE(descriptorID)
        writer.writeUInt8(0) // SPICE_IMAGE_TYPE_BITMAP
        writer.writeUInt8(0) // no image-cache flags
        writer.writeUInt32LE(UInt32(Self.bitmapWidth))
        writer.writeUInt32LE(UInt32(Self.bitmapHeight))
        writer.writeUInt8(8) // SPICE_BITMAP_FMT_32BIT (xRGB)
        writer.writeUInt8(0x04) // top-down
        writer.writeUInt32LE(UInt32(Self.bitmapWidth))
        writer.writeUInt32LE(UInt32(Self.bitmapHeight))
        writer.writeUInt32LE(UInt32(Self.bitmapWidth * 4))
        writer.writeUInt32LE(0) // no palette for true-color bitmap
        writer.writeBytes(payload)
        return writer.data
    }

    private func writeRect(
        to writer: inout ByteWriter,
        top: Int,
        left: Int,
        bottom: Int,
        right: Int
    ) {
        writer.writeInt32LE(Int32(top))
        writer.writeInt32LE(Int32(left))
        writer.writeInt32LE(Int32(bottom))
        writer.writeInt32LE(Int32(right))
    }

    private func encodeMini<Message: SpiceGeneratedMessage>(_ message: Message) throws -> Data {
        guard let messageID = Message.messageID else {
            throw CPUHotPathBenchmarkError.missingMessageID
        }
        var body = ByteWriter(capacity: Message.minimumWireSize)
        try message.encode(to: &body)
        return encodeMini(id: messageID, body: body.data)
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter(capacity: body.count + 6)
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }

    private func pixel(_ snapshot: FrameSnapshot, x: Int, y: Int) -> [UInt8] {
        let offset = y * snapshot.bytesPerRow + x * 4
        return Array(snapshot.pixels[offset..<(offset + 4)])
    }
}

private enum CPUHotPathBackend: String {
    case dataOnly = "data-only"
    case cpuIOSurface = "cpu-iosurface"
}

private enum CPUHotPathResolution: String {
    case p720 = "720p"
    case p4K = "4k"

    var width: Int {
        switch self {
        case .p720: 1_280
        case .p4K: 3_840
        }
    }

    var height: Int {
        switch self {
        case .p720: 720
        case .p4K: 2_160
        }
    }
}

private enum CPUHotPathBenchmarkError: Error, CustomStringConvertible {
    case invalidBackend(String)
    case invalidResolution(String)
    case invalidFrameCount(String)
    case missingMessageID
    case revisionedIOSurfaceUnavailable
    case inputDrainTimeout
    case publisherCompletionTimeout
    case unexpectedTransportCompletion

    var description: String {
        switch self {
        case let .invalidBackend(value):
            "invalid CPU hot-path backend: \(value)"
        case let .invalidResolution(value):
            "invalid CPU hot-path resolution: \(value)"
        case let .invalidFrameCount(value):
            "invalid CPU hot-path frame count: \(value)"
        case .missingMessageID:
            "surface-create message has no wire ID"
        case .revisionedIOSurfaceUnavailable:
            "revisioned IOSurface is unavailable on this host"
        case .inputDrainTimeout:
            "paced benchmark input did not drain before timeout"
        case .publisherCompletionTimeout:
            "publisher did not complete the final benchmark revision before timeout"
        case .unexpectedTransportCompletion:
            "paced benchmark transport unexpectedly completed without EOF"
        }
    }
}

private actor CPUHotPathCompletionGate {
    private var isComplete = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func complete() {
        guard !isComplete else {
            return
        }
        isComplete = true
        let continuations = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(returning: true)
        }
    }

    func wait(timeout: Duration) async -> Bool {
        guard !isComplete else {
            return true
        }
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOut(id: id)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            if isComplete {
                continuation.resume(returning: true)
            } else {
                waiters[id] = continuation
            }
        }
    }

    private func timeOut(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }
}

private actor CPUHotPathPacedTransport: SpiceTransport {
    private let prefix: Data
    private let frameWire: Data
    private let frameCount: Int
    private let frameIntervalMilliseconds: Int64
    private let inputDrainedGate: CPUHotPathCompletionGate
    private let finishGate: CPUHotPathCompletionGate
    private let finishTimeout: Duration
    private let clock = ContinuousClock()

    private var prefixOffset = 0
    private var frameOffset = 0
    private var completedFrames = 0
    private var firstFrameStart: ContinuousClock.Instant?
    private var didAwaitFinish = false
    private var isConnected = false
    private var isClosed = false
    private(set) var writtenBytes = 0

    init(
        prefix: Data,
        frameWire: Data,
        frameCount: Int,
        frameIntervalMilliseconds: Int64,
        inputDrainedGate: CPUHotPathCompletionGate,
        finishGate: CPUHotPathCompletionGate,
        finishTimeout: Duration
    ) {
        self.prefix = prefix
        self.frameWire = frameWire
        self.frameCount = frameCount
        self.frameIntervalMilliseconds = frameIntervalMilliseconds
        self.inputDrainedGate = inputDrainedGate
        self.finishGate = finishGate
        self.finishTimeout = finishTimeout
    }

    func connect() async throws(TransportError) {
        guard !isClosed else {
            throw .connectionClosed
        }
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard isConnected, !isClosed else {
            throw .connectionClosed
        }
        guard minimum > 0, maximum >= minimum else {
            throw .connectionFailed("invalid benchmark read bounds")
        }

        if prefixOffset < prefix.count {
            let end = min(prefix.count, prefixOffset + maximum)
            let bytes = prefix.subdata(in: prefixOffset..<end)
            prefixOffset = end
            return bytes
        }

        if completedFrames < frameCount {
            if frameOffset == 0 {
                let start: ContinuousClock.Instant
                if let firstFrameStart {
                    start = firstFrameStart
                } else {
                    let now = clock.now
                    firstFrameStart = now
                    start = now
                }
                try await waitUntil(
                    start.advanced(by: .milliseconds(
                        Int64(completedFrames) * frameIntervalMilliseconds
                    ))
                )
            }

            let end = min(frameWire.count, frameOffset + maximum)
            let bytes = frameWire.subdata(in: frameOffset..<end)
            frameOffset = end
            if frameOffset == frameWire.count {
                frameOffset = 0
                completedFrames += 1
            }
            return bytes
        }

        if !didAwaitFinish {
            didAwaitFinish = true
            await inputDrainedGate.complete()
            guard await finishGate.wait(timeout: finishTimeout) else {
                throw .timeout
            }
        }
        throw .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected, !isClosed else {
            throw .connectionClosed
        }
        writtenBytes += data.count
    }

    func close() async {
        isClosed = true
        isConnected = false
    }

    private func waitUntil(_ deadline: ContinuousClock.Instant) async throws(TransportError) {
        let now = clock.now
        guard now < deadline else {
            return
        }
        do {
            try await Task.sleep(for: now.duration(to: deadline))
        } catch {
            throw .cancelled
        }
    }
}

private actor CPUHotPathFrameSink {
    private var timestamps: [UInt64] = []
    private var latestFrame: FrameSnapshot?
    private var lastPublishedRevision: UInt64 = 0
    private let surfaceID: UInt32
    private let expectedRevision: UInt64
    private let finalFrameGate: CPUHotPathCompletionGate

    init(
        surfaceID: UInt32,
        expectedRevision: UInt64,
        finalFrameGate: CPUHotPathCompletionGate
    ) {
        self.surfaceID = surfaceID
        self.expectedRevision = expectedRevision
        self.finalFrameGate = finalFrameGate
    }

    func consume(_ frame: FrameSnapshot) async {
        latestFrame = frame
        timestamps.append(DispatchTime.now().uptimeNanoseconds)
        guard frame.surfaceID == surfaceID else {
            return
        }
        lastPublishedRevision = max(lastPublishedRevision, frame.revision)
        if frame.revision == expectedRevision {
            await finalFrameGate.complete()
        }
    }

    func metrics() -> (
        frames: UInt64,
        p95IntervalNanoseconds: UInt64,
        lastPublishedRevision: UInt64
    ) {
        guard timestamps.count > 1 else {
            return (UInt64(timestamps.count), 0, lastPublishedRevision)
        }
        var intervals = zip(timestamps.dropFirst(), timestamps).map { later, earlier in
            later >= earlier ? later - earlier : 0
        }
        intervals.sort()
        let index = min(
            intervals.count - 1,
            Int((Double(intervals.count) * 0.95).rounded(.up)) - 1
        )
        return (UInt64(timestamps.count), intervals[index], lastPublishedRevision)
    }
}

private struct CPUHotPathBenchmarkResult: Encodable {
    let schemaVersion = 1
    let backend: String
    let resolution: String
    let width: Int
    let height: Int
    let frames: Int
    let commands: Int
    let diagnosticsEnabled: Bool
    let commandsPerFrame: Int
    let bitmapWidth: Int
    let bitmapHeight: Int
    let bitmapPayloadBytes: Int
    let publisherIntervalNanoseconds: UInt64
    let wallNanoseconds: UInt64
    let processCPUNanoseconds: UInt64
    let cpuNanosecondsPerFrame: UInt64
    let cpuNanosecondsPerCommand: UInt64
    let cpuNanosecondsPerPublishedFrame: UInt64
    let residentBytes: UInt64
    let peakResidentBytes: UInt64
    let publishedFPSMilli: UInt64
    let publisherP95IntervalNanoseconds: UInt64
    let lastPublishedRevision: UInt64
    let publisherSubmissions: UInt64
    let publisherSnapshotAttempts: UInt64
    let publisherEmittedFrames: UInt64
    let publisherStaleSnapshots: UInt64
    let publisherPendingEvictions: UInt64
    let publisherPendingSurfaces: Int
    let damageOperations: UInt64
    let damageBytes: UInt64
    let damageRectanglesBeforeMerge: UInt64
    let damageRectanglesAfterMerge: UInt64
    let fullDamageByCount: UInt64
    let fullDamageByArea: UInt64
    let fullDamageByExplicit: UInt64
    let fullDamageBySurfaceInitialization: UInt64
    let fullDamageByNewSlot: UInt64
    let fullDamageByHistoryGap: UInt64
    let snapshots: UInt64
    let fullFrameCopyBytes: UInt64
    let partialFrameCopyBytes: UInt64
    let snapshotCatchUpCPUCopyBytes: UInt64
    let cpuMaterializations: UInt64
    let cpuMaterializationBytes: UInt64
    let poolExhaustions: UInt64
    let inFlightLeases: Int
    let revisionedBackingEnabled: Bool
    let revisionedAllocatedFrames: Int
    let revisionedAllocatedBytes: Int
    let recommendedMaximumWorkingSetSize: UInt64
    let currentMetalAllocatedSize: UInt64
    let gpuCopyBytes: UInt64
    let gpuErrors: UInt64
    let compositorErrors: UInt64
    let nativeVideoFrames: UInt64
    let nativeVideoFallbacks: UInt64
    let revisionedSnapshotReuses: UInt64
    let revisionedSnapshotUploads: UInt64
    let dataBackendSnapshots: UInt64
    let revisionedSnapshotFallbacks: UInt64
    let unifiedBackingDisables: UInt64
    let wireFramerNextSamplePeriod: UInt64
    let wireFramerNextSamples: UInt64
    let wireFramerNextSampledNanoseconds: UInt64
    let wireFramerAppendSamplePeriod: UInt64
    let wireFramerAppendSamples: UInt64
    let wireFramerAppendSampledNanoseconds: UInt64
    let displayMessageHandlingSamplePeriod: UInt64
    let displayMessageHandlingSamples: UInt64
    let displayMessageHandlingSampledNanoseconds: UInt64
    let displayMessageDecodeSamplePeriod: UInt64
    let displayMessageDecodeSamples: UInt64
    let displayMessageDecodeSampledNanoseconds: UInt64
    let bitmapSurfaceStoreRoundTripSamplePeriod: UInt64
    let bitmapSurfaceStoreRoundTripSamples: UInt64
    let bitmapSurfaceStoreRoundTripSampledNanoseconds: UInt64
    let publisherSubmitRoundTripSamplePeriod: UInt64
    let publisherSubmitRoundTripSamples: UInt64
    let publisherSubmitRoundTripSampledNanoseconds: UInt64
    let frameEmitSamplePeriod: UInt64
    let frameEmitSamples: UInt64
    let frameEmitSampledNanoseconds: UInt64
    let bitmapValidationSamplePeriod: UInt64
    let bitmapValidationSamples: UInt64
    let bitmapValidationSampledNanoseconds: UInt64
    let bitmapMutationSamplePeriod: UInt64
    let bitmapMutationSamples: UInt64
    let bitmapMutationSampledNanoseconds: UInt64
    let bitmapDamageJournalSamplePeriod: UInt64
    let bitmapDamageJournalSamples: UInt64
    let bitmapDamageJournalSampledNanoseconds: UInt64
    let snapshotCheckoutSamplePeriod: UInt64
    let snapshotCheckoutSamples: UInt64
    let snapshotCheckoutSampledNanoseconds: UInt64
    let snapshotDamagePlanSamplePeriod: UInt64
    let snapshotDamagePlanSamples: UInt64
    let snapshotDamagePlanSampledNanoseconds: UInt64
    let snapshotCPUCopySamplePeriod: UInt64
    let snapshotCPUCopySamples: UInt64
    let snapshotCPUCopySampledNanoseconds: UInt64
    let snapshotFinishSamplePeriod: UInt64
    let snapshotFinishSamples: UInt64
    let snapshotFinishSampledNanoseconds: UInt64
}

private func processCPUNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
}

private func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                rebound,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else {
        return 0
    }
    return UInt64(info.resident_size)
}

private func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
        return 0
    }
    return UInt64(max(0, usage.ru_maxrss))
}
