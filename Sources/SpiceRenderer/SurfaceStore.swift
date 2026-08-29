import CSpicePixelOps
import Foundation
import SpiceCodecs
import SpiceIOSurface
import SpiceMetalCompositor
import Synchronization

package enum SurfacePixelFormat: UInt32, Sendable, Equatable {
    case xRGB8888 = 32
    case argb8888 = 96
}

package enum RawBitmapFormat: UInt8, Sendable, Equatable {
    case xRGB8888 = 8
    case argb8888 = 9
}

package struct PixelRect: Sendable, Equatable {
    package let x: Int
    package let y: Int
    package let width: Int
    package let height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct RawBitmap: Sendable, Equatable {
    package let format: RawBitmapFormat
    package let width: Int
    package let height: Int
    package let stride: Int
    package let topDown: Bool
    package let pixels: Data

    package init(
        format: RawBitmapFormat,
        width: Int,
        height: Int,
        stride: Int,
        topDown: Bool,
        pixels: consuming Data
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.stride = stride
        self.topDown = topDown
        self.pixels = pixels
    }
}

package struct SurfaceRevision: Sendable, Hashable {
    package let surfaceID: UInt32
    package let lifecycleGeneration: UInt64
    package let revision: UInt64

    package init(surfaceID: UInt32, lifecycleGeneration: UInt64, revision: UInt64) {
        self.surfaceID = surfaceID
        self.lifecycleGeneration = lifecycleGeneration
        self.revision = revision
    }
}

/// Identifies the latest non-video mutation applied to a surface. Stream frames
/// may advance the public revision without invalidating later frames from the
/// same wire-ordered stream, while any subsequent draw/copy command changes
/// this barrier and makes an older asynchronous decode stale.
package struct SurfaceMutationBarrier: Sendable, Hashable {
    package let surfaceID: UInt32
    package let lifecycleGeneration: UInt64
    package let generation: UInt64
}

/// Surface-wide wire order shared by every video stream targeting the surface.
package struct SurfaceVideoSequence: Sendable, Hashable {
    package let surfaceID: UInt32
    package let lifecycleGeneration: UInt64
    package let value: UInt64

    package init(surfaceID: UInt32, lifecycleGeneration: UInt64, value: UInt64) {
        self.surfaceID = surfaceID
        self.lifecycleGeneration = lifecycleGeneration
        self.value = value
    }
}

/// Surface geometry and identity without materializing a frame snapshot.
package struct SurfaceDescriptor: Sendable, Equatable {
    package let surfaceID: UInt32
    package let width: Int
    package let height: Int
    package let bytesPerRow: Int
    package let format: SurfacePixelFormat
    package let lifecycleGeneration: UInt64
    package let revision: UInt64
    package let mutationGeneration: UInt64

    package var surfaceRevision: SurfaceRevision {
        SurfaceRevision(
            surfaceID: surfaceID,
            lifecycleGeneration: lifecycleGeneration,
            revision: revision
        )
    }

    package var mutationBarrier: SurfaceMutationBarrier {
        SurfaceMutationBarrier(
            surfaceID: surfaceID,
            lifecycleGeneration: lifecycleGeneration,
            generation: mutationGeneration
        )
    }
}

package struct SurfaceStoreMetrics: Sendable, Equatable {
    package let mutationTransactions: UInt64
    package let temporaryCopyBytes: UInt64
    package let bulkCopyCalls: UInt64
    package let rowCopyCalls: UInt64
    package let fillKernelCalls: UInt64
    package let damageOperations: UInt64
    package let damageBytes: UInt64
    package let snapshots: UInt64
    package let fullFrameCopyBytes: UInt64
    package let partialFrameCopyBytes: UInt64
    package let directIOSurfaceWriteBytes: UInt64
    package let cpuMaterializations: UInt64
    package let cpuMaterializationBytes: UInt64
    package let poolExhaustions: UInt64
    package let inFlightLeases: Int
    package let revisionedBackingEnabled: Bool
    package let revisionedAllocatedFrames: Int
    package let revisionedAllocatedBytes: Int
    package let gpuCopyBytes: UInt64
    package let gpuErrors: UInt64
    package let compositorErrors: UInt64
    package let recommendedMaximumWorkingSetSize: UInt64
    package let currentMetalAllocatedSize: UInt64
    package let nativeVideoFrames: UInt64
    package let nativeVideoFallbacks: UInt64
}

package typealias SurfaceOperationWaiterObserver = @Sendable (
    _ surfaceID: UInt32,
    _ reservationID: UInt64
) async -> Void

package struct SurfaceOperationReservationDiagnostics: Sendable, Equatable {
    package let activeSurfaceCount: Int
    package let waitingCount: Int
    package let grantedWaiterCount: Int
    package let reservedCount: Int

    package init(
        activeSurfaceCount: Int = 0,
        waitingCount: Int = 0,
        grantedWaiterCount: Int = 0,
        reservedCount: Int = 0
    ) {
        self.activeSurfaceCount = activeSurfaceCount
        self.waitingCount = waitingCount
        self.grantedWaiterCount = grantedWaiterCount
        self.reservedCount = reservedCount
    }
}

private final class SurfaceOperationCancellation: Sendable {
    private let cancelled = Mutex(false)

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

package final class FramePixelStorage: @unchecked Sendable {
    private struct State {
        var pixels: Data?
    }

    private let state: Mutex<State>
    private let ioSurfaceFrame: IOSurfaceFrame?
    private let expectedPixelBytes: Int?
    private let materializationMetrics: FrameMaterializationMetrics?

    package init(
        pixels: consuming Data?,
        ioSurfaceFrame: IOSurfaceFrame?,
        expectedPixelBytes: Int? = nil,
        materializationMetrics: FrameMaterializationMetrics? = nil
    ) {
        state = Mutex(State(pixels: pixels))
        self.ioSurfaceFrame = ioSurfaceFrame
        self.expectedPixelBytes = expectedPixelBytes
        self.materializationMetrics = materializationMetrics
    }

    package func pixels() -> Data {
        state.withLock { state in
            if let pixels = state.pixels {
                return pixels
            }
            guard let pixels = ioSurfaceFrame?.copyPixels(),
                  expectedPixelBytes.map({ $0 == pixels.count }) ?? true
            else {
                preconditionFailure("committed IOSurface frame could not be materialized")
            }
            state.pixels = pixels
            materializationMetrics?.record(bytes: pixels.count)
            return pixels
        }
    }

    package var backingIOSurfaceFrame: IOSurfaceFrame? {
        ioSurfaceFrame
    }
}

package final class FrameMaterializationMetrics: Sendable {
    private struct State {
        var count: UInt64 = 0
        var bytes: UInt64 = 0
    }

    private let state = Mutex(State())

    package func record(bytes: Int) {
        state.withLock { state in
            state.count &+= 1
            state.bytes &+= UInt64(max(0, bytes))
        }
    }

    package func snapshot() -> (count: UInt64, bytes: UInt64) {
        state.withLock { ($0.count, $0.bytes) }
    }
}

private final class SurfacePublicationDamageLease: Sendable {
    private enum State: Sendable {
        case pending
        case committed
        case restoring(Task<Void, Never>)
        case restored
    }

    private let state = Mutex(State.pending)
    private let restoreOperation: @Sendable () async -> Void

    init(restoreOperation: @escaping @Sendable () async -> Void) {
        self.restoreOperation = restoreOperation
    }

    var identifier: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    func commit() {
        state.withLock { state in
            guard case .pending = state else { return }
            state = .committed
        }
    }

    func restore() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            switch state {
            case .pending:
                let restoreOperation = self.restoreOperation
                let task = Task { await restoreOperation() }
                state = .restoring(task)
                return task
            case let .restoring(task):
                return task
            case .committed, .restored:
                return nil
            }
        }
        guard let task else { return }
        await task.value
        state.withLock { state in
            if case .restoring = state {
                state = .restored
            }
        }
    }
}

package struct FrameSnapshot: Sendable, Equatable {
    package let surfaceID: UInt32
    package let width: Int
    package let height: Int
    package let bytesPerRow: Int
    package let lifecycleGeneration: UInt64
    package let revision: UInt64
    package let pixelStorage: FramePixelStorage
    package let ioSurfaceFrame: IOSurfaceFrame?
    package let publicationDamage: SurfaceDamageJournal
    package let isAdvancedVideoFrame: Bool
    private let publicationDamageLease: SurfacePublicationDamageLease?

    package var pixels: Data {
        pixelStorage.pixels()
    }

    package var surfaceRevision: SurfaceRevision {
        SurfaceRevision(
            surfaceID: surfaceID,
            lifecycleGeneration: lifecycleGeneration,
            revision: revision
        )
    }

    package init(
        surfaceID: UInt32,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        lifecycleGeneration: UInt64 = 0,
        revision: UInt64 = 0,
        pixels: consuming Data?,
        ioSurfaceFrame: IOSurfaceFrame?,
        materializationMetrics: FrameMaterializationMetrics? = nil,
        publicationDamage: SurfaceDamageJournal? = nil,
        isAdvancedVideoFrame: Bool = false
    ) {
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.lifecycleGeneration = lifecycleGeneration
        self.revision = revision
        pixelStorage = FramePixelStorage(
            pixels: pixels,
            ioSurfaceFrame: ioSurfaceFrame,
            expectedPixelBytes: width * height * 4,
            materializationMetrics: materializationMetrics
        )
        self.ioSurfaceFrame = ioSurfaceFrame
        self.publicationDamage = publicationDamage ?? SurfaceDamageJournal(
            width: width,
            height: height,
            initiallyFull: true
        )
        self.isAdvancedVideoFrame = isAdvancedVideoFrame
        publicationDamageLease = nil
    }

    package init(
        surfaceID: UInt32,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        lifecycleGeneration: UInt64,
        revision: UInt64,
        pixelStorage: FramePixelStorage,
        ioSurfaceFrame: IOSurfaceFrame,
        publicationDamage: SurfaceDamageJournal? = nil,
        isAdvancedVideoFrame: Bool = false
    ) {
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.lifecycleGeneration = lifecycleGeneration
        self.revision = revision
        self.pixelStorage = pixelStorage
        self.ioSurfaceFrame = ioSurfaceFrame
        self.publicationDamage = publicationDamage ?? SurfaceDamageJournal(
            width: width,
            height: height,
            initiallyFull: true
        )
        self.isAdvancedVideoFrame = isAdvancedVideoFrame
        publicationDamageLease = nil
    }

    package func withPublicationDamage(
        _ damage: SurfaceDamageJournal
    ) -> FrameSnapshot {
        return FrameSnapshot(
            surfaceID: surfaceID,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            lifecycleGeneration: lifecycleGeneration,
            revision: revision,
            pixelStorage: pixelStorage,
            ioSurfaceFrame: ioSurfaceFrame,
            publicationDamage: damage,
            isAdvancedVideoFrame: isAdvancedVideoFrame,
            publicationDamageLease: publicationDamageLease
        )
    }

    package var publicationDamageLeaseIdentifier: ObjectIdentifier? {
        publicationDamageLease?.identifier
    }

    package func commitPublicationDamage() {
        publicationDamageLease?.commit()
    }

    package func restorePublicationDamage() async {
        await publicationDamageLease?.restore()
    }

    fileprivate func withPublicationDamage(
        _ damage: SurfaceDamageJournal,
        lease: SurfacePublicationDamageLease
    ) -> FrameSnapshot {
        FrameSnapshot(
            surfaceID: surfaceID,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            lifecycleGeneration: lifecycleGeneration,
            revision: revision,
            pixelStorage: pixelStorage,
            ioSurfaceFrame: ioSurfaceFrame,
            publicationDamage: damage,
            isAdvancedVideoFrame: isAdvancedVideoFrame,
            publicationDamageLease: lease
        )
    }

    private init(
        surfaceID: UInt32,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        lifecycleGeneration: UInt64,
        revision: UInt64,
        pixelStorage: FramePixelStorage,
        ioSurfaceFrame: IOSurfaceFrame?,
        publicationDamage: SurfaceDamageJournal,
        isAdvancedVideoFrame: Bool,
        publicationDamageLease: SurfacePublicationDamageLease?
    ) {
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.lifecycleGeneration = lifecycleGeneration
        self.revision = revision
        self.pixelStorage = pixelStorage
        self.ioSurfaceFrame = ioSurfaceFrame
        self.publicationDamage = publicationDamage
        self.isAdvancedVideoFrame = isAdvancedVideoFrame
        self.publicationDamageLease = publicationDamageLease
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.surfaceID == rhs.surfaceID
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.bytesPerRow == rhs.bytesPerRow
            && lhs.lifecycleGeneration == rhs.lifecycleGeneration
            && lhs.revision == rhs.revision
            && lhs.publicationDamage == rhs.publicationDamage
            && lhs.isAdvancedVideoFrame == rhs.isAdvancedVideoFrame
            && lhs.pixels == rhs.pixels
    }
}

package struct RenderLimits: Sendable, Equatable {
    package var maximumDimension: Int
    package var maximumSurfaceBytes: Int
    package var maximumTotalSurfaceBytes: Int

    package init(
        maximumDimension: Int = 16_384,
        maximumSurfaceBytes: Int = 256 * 1_024 * 1_024,
        maximumTotalSurfaceBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumDimension = maximumDimension
        self.maximumSurfaceBytes = maximumSurfaceBytes
        self.maximumTotalSurfaceBytes = maximumTotalSurfaceBytes
    }
}

package enum RenderError: Error, Sendable, Equatable {
    case storeClosed
    case operationCancelled
    case duplicateSurface(UInt32)
    case unknownSurface(UInt32)
    case unsupportedSurfaceFormat(UInt32)
    case invalidDimensions(width: Int, height: Int)
    case surfaceTooLarge(bytes: Int, maximum: Int)
    case surfaceBudgetExceeded(requestedBytes: Int, allocatedBytes: Int, maximum: Int)
    case invalidRectangle
    case invalidBitmap
    case backingMaterializationFailed
    case integerOverflow
    case regionClipLimitExceeded(actual: Int, maximum: Int)
    case regionSegmentLimitExceeded(actual: Int, maximum: Int)
}

package enum SurfaceVideoCompositionError: Error, Sendable, Equatable {
    case staleSurface
    case render(RenderError)
    case compositor(SpiceMetalCompositorError)

    package var disablesStreamGeneration: Bool {
        guard case let .compositor(error) = self else {
            return false
        }
        return error.fallback == .streamGeneration
    }
}

extension SurfaceVideoCompositionError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .staleSurface:
            "surface changed while native video composition was in flight"
        case let .render(error):
            String(describing: error)
        case let .compositor(error):
            error.description
        }
    }
}

package actor SurfaceStore {
    private enum SurfaceOperationWaitOutcome: Sendable {
        case acquired
        case cancelled
    }

    private enum SurfaceOperationReservation {
        case queued(
            surfaceID: UInt32,
            continuation: CheckedContinuation<SurfaceOperationWaitOutcome, Never>
        )
        case granted(surfaceID: UInt32)
        case cancelledAfterGrant(surfaceID: UInt32)
    }

    private enum CanonicalCPUMutation: Sendable {
        case fill(region: PixelRegion, colorBGRA: UInt32)
        case sameSurfaceCopy(
            region: PixelRegion,
            destination: PixelRect,
            source: PixelRect
        )
        case bitmapCopy(
            region: PixelRegion,
            destination: PixelRect,
            bitmap: RawBitmap,
            source: PixelRect,
            preservesAlpha: Bool
        )

        var region: PixelRegion {
            switch self {
            case let .fill(region, _),
                 let .sameSurfaceCopy(region, _, _),
                 let .bitmapCopy(region, _, _, _, _):
                region
            }
        }
    }

    private struct PixelKernelMetrics {
        var bulkCopyCalls: UInt64 = 0
        var rowCopyCalls: UInt64 = 0
        var fillKernelCalls: UInt64 = 0
        var writtenBytes: UInt64 = 0
    }

    private enum CanonicalMutationAttempt {
        case notEligible
        case fallback
        case committed(SurfaceRevision)
    }

    private struct Surface: Sendable {
        let id: UInt32
        let width: Int
        let height: Int
        let format: SurfacePixelFormat
        let lifecycleGeneration: UInt64
        let memoryLease: SurfaceMemoryLease
        var revision: UInt64
        var mutationGeneration: UInt64
        var latestVideoSequence: UInt64
        var latestAdvancedVideoRevision: UInt64?
        var storage: SurfaceStorage

        var bytesPerRow: Int { width * 4 }

        var pixels: Data {
            _read {
                yield storage.pixels
            }
            _modify {
                yield &storage.pixels
            }
        }
    }

    private let limits: RenderLimits
    private let framePool: IOSurfaceFramePool
    private let memoryBudget: SurfaceMemoryBudget
    private let revisionedFramePool: RevisionedIOSurfacePool?
    private let revisionedNamespace = RevisionedIOSurfaceNamespace()
    private let metalCompositor: SpiceMetalCompositor?
    private let metalCompositorInitializationError: SpiceMetalCompositorError?
    private let compositorFailureForAttempt: @Sendable (Int) -> SpiceMetalCompositorError?
    private let surfaceOperationWaiterWillRegister: SurfaceOperationWaiterObserver?
    private let surfaceOperationGrantWillBeClaimed: SurfaceOperationWaiterObserver?
    private var compositorAttempt = 0
    private let materializationMetrics = FrameMaterializationMetrics()
    private var surfaces: [UInt32: Surface] = [:]
    /// One shared lazy readback cache for the current IOSurface revision. Every
    /// snapshot of that revision reuses the same cache and lease; the cache is
    /// dropped when the revision stops being canonical.
    private var currentFramePixelStorage: [UInt32: (
        revision: SurfaceRevision,
        storage: FramePixelStorage
    )] = [:]
    private var lifecycleGenerations: [UInt32: UInt64] = [:]
    private var mutationTransactions: UInt64 = 0
    private var temporaryCopyBytes: UInt64 = 0
    private var bulkCopyCalls: UInt64 = 0
    private var rowCopyCalls: UInt64 = 0
    private var fillKernelCalls: UInt64 = 0
    private var damageOperations: UInt64 = 0
    private var damageBytes: UInt64 = 0
    private var snapshots: UInt64 = 0
    private var fullFrameCopyBytes: UInt64 = 0
    private var partialFrameCopyBytes: UInt64 = 0
    private var directIOSurfaceWriteBytes: UInt64 = 0
    private var poolExhaustions: UInt64 = 0
    private var nativeVideoFrames: UInt64 = 0
    private var nativeVideoFallbacks: UInt64 = 0
    private var compositorErrors: UInt64 = 0
    private var gpuCopyBytes: UInt64 = 0
    private var revisionedGPUErrors: UInt64 = 0
    private var activeSurfaceOperations: Set<UInt32> = []
    private var surfaceOperationWaiters: [UInt32: [UInt64]] = [:]
    private var surfaceOperationReservations: [UInt64: SurfaceOperationReservation] = [:]
    private var reservedSurfaceOperationReservationIDs: Set<UInt64> = []
    private var nextSurfaceOperationReservationID: UInt64 = 0
    private var rejectsNewOperations = false
    private var closeCompleted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    package init(
        limits: RenderLimits = .init(),
        framePool: IOSurfaceFramePool = .shared,
        memoryBudget: SurfaceMemoryBudget? = nil,
        backingPolicy: SurfaceBackingPolicy = .automatic,
        surfaceOperationWaiterWillRegister: SurfaceOperationWaiterObserver? = nil,
        surfaceOperationGrantWillBeClaimed: SurfaceOperationWaiterObserver? = nil,
        compositorFailureForAttempt: @escaping @Sendable (Int) -> SpiceMetalCompositorError? = {
            _ in nil
        }
    ) {
        self.limits = limits
        self.framePool = framePool
        self.memoryBudget = memoryBudget ?? SurfaceMemoryBudget(
            maximumBytes: limits.maximumTotalSurfaceBytes
        )
        self.compositorFailureForAttempt = compositorFailureForAttempt
        self.surfaceOperationWaiterWillRegister = surfaceOperationWaiterWillRegister
        self.surfaceOperationGrantWillBeClaimed = surfaceOperationGrantWillBeClaimed
        let selectedRevisionedPool: RevisionedIOSurfacePool?
        switch backingPolicy {
        case .automatic:
            selectedRevisionedPool = RevisionedIOSurfacePool.sharedIfSupported
        case .dataOnly:
            selectedRevisionedPool = nil
        case let .revisionedIOSurface(pool):
            selectedRevisionedPool = pool
        }
        revisionedFramePool = selectedRevisionedPool
        if selectedRevisionedPool != nil {
            do {
                metalCompositor = try SpiceMetalCompositor()
                metalCompositorInitializationError = nil
            } catch {
                metalCompositor = nil
                metalCompositorInitializationError = error
            }
        } else {
            metalCompositor = nil
            metalCompositorInitializationError = nil
        }
    }

    package func create(
        id: UInt32,
        width: UInt32,
        height: UInt32,
        format rawFormat: UInt32
    ) async throws(RenderError) {
        try await acquireSurfaceOperation(surfaceID: id)
        defer { releaseSurfaceOperation(surfaceID: id) }
        guard surfaces[id] == nil else {
            throw .duplicateSurface(id)
        }
        guard let width = Int(exactly: width), let height = Int(exactly: height),
              width > 0, height > 0,
              width <= limits.maximumDimension, height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: Int(width), height: Int(height))
        }
        guard let format = SurfacePixelFormat(rawValue: rawFormat) else {
            throw .unsupportedSurfaceFormat(rawFormat)
        }
        let byteCount = try checkedByteCount(width: width, height: height)
        guard let memoryLease = memoryBudget.checkout(bytes: byteCount) else {
            let budget = memoryBudget.metrics()
            throw .surfaceBudgetExceeded(
                requestedBytes: byteCount,
                allocatedBytes: budget.allocatedBytes,
                maximum: budget.maximumBytes
            )
        }
        let lifecycleGeneration = try advanceLifecycleGeneration(for: id)
        currentFramePixelStorage[id] = nil
        surfaces[id] = Surface(
            id: id,
            width: width,
            height: height,
            format: format,
            lifecycleGeneration: lifecycleGeneration,
            memoryLease: memoryLease,
            revision: 0,
            mutationGeneration: 0,
            latestVideoSequence: 0,
            latestAdvancedVideoRevision: nil,
            storage: SurfaceStorage(
                pixels: Data(repeating: 0, count: byteCount),
                width: width,
                height: height,
                revisionedPool: revisionedFramePool,
                revisionedNamespace: revisionedNamespace
            )
        )
    }

    package func destroy(id: UInt32) async throws(RenderError) {
        try await acquireSurfaceOperation(surfaceID: id)
        defer { releaseSurfaceOperation(surfaceID: id) }
        guard let surface = surfaces[id] else {
            throw .unknownSurface(id)
        }
        let lifecycleGeneration = try nextLifecycleGeneration(for: id)
        surfaces.removeValue(forKey: id)
        currentFramePixelStorage[id] = nil
        if let unified = surface.storage.unifiedBacking {
            unified.pool.retire(namespace: unified.namespace, surfaceID: id)
        }
        lifecycleGenerations[id] = lifecycleGeneration
    }

    package func close() async {
        if closeCompleted {
            return
        }
        if rejectsNewOperations {
            await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
            }
            return
        }
        rejectsNewOperations = true
        let surfaceIDs = surfaces.keys.sorted()
        for surfaceID in surfaceIDs {
            await acquireSurfaceOperationUnconditionally(surfaceID: surfaceID)
            if let surface = surfaces.removeValue(forKey: surfaceID),
               let unified = surface.storage.unifiedBacking
            {
                unified.pool.retire(
                    namespace: unified.namespace,
                    surfaceID: surfaceID
                )
            }
            currentFramePixelStorage[surfaceID] = nil
            releaseSurfaceOperation(surfaceID: surfaceID)
        }
        closeCompleted = true
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    @discardableResult
    package func fill(
        surfaceID: UInt32,
        rectangle: PixelRect,
        colorARGB: UInt32
    ) async throws(RenderError) -> SurfaceRevision {
        try await acquireSurfaceOperation(surfaceID: surfaceID)
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }
        var surface = try surface(id: surfaceID)
        try validate(rectangle, in: surface)
        let blue = UInt8(truncatingIfNeeded: colorARGB)
        let green = UInt8(truncatingIfNeeded: colorARGB >> 8)
        let red = UInt8(truncatingIfNeeded: colorARGB >> 16)
        let alpha = surface.format == .argb8888
            ? UInt8(truncatingIfNeeded: colorARGB >> 24)
            : 255
        let colorBGRA = UInt32(blue)
            | UInt32(green) << 8
            | UInt32(red) << 16
            | UInt32(alpha) << 24
        let nextRevision = try advancedRevision(surface.revision)
        let nextMutationGeneration = try advancedRevision(surface.mutationGeneration)
        let region = try PixelRegion(
            destination: rectangle,
            surfaceBounds: PixelRect(
                x: 0,
                y: 0,
                width: surface.width,
                height: surface.height
            ),
            clips: nil
        )
        switch try await applyCanonicalMutation(
            to: surface,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration,
            mutation: .fill(region: region, colorBGRA: colorBGRA)
        ) {
        case let .committed(revision):
            return revision
        case .fallback, .notEligible:
            surface = try self.surface(id: surfaceID)
        }
        try prepareForMutation(&surface)
        surface.revision = nextRevision
        surface.mutationGeneration = nextMutationGeneration
        fillPixels(in: &surface, rectangle: rectangle, colorBGRA: colorBGRA)
        surface.storage.recordDamage(rectangle, revision: surface.revision)
        currentFramePixelStorage[surfaceID] = nil
        surfaces[surfaceID] = surface
        recordDamage(rectangle)
        return surfaceRevision(of: surface)
    }

    @discardableResult
    package func copyBits(
        surfaceID: UInt32,
        destination: PixelRect,
        sourceX: Int,
        sourceY: Int
    ) async throws(RenderError) -> SurfaceRevision {
        try await acquireSurfaceOperation(surfaceID: surfaceID)
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }
        return try await copyBitsUnlocked(
            surfaceID: surfaceID,
            destination: destination,
            sourceX: sourceX,
            sourceY: sourceY
        )
    }

    private func copyBitsUnlocked(
        surfaceID: UInt32,
        destination: PixelRect,
        sourceX: Int,
        sourceY: Int
    ) async throws(RenderError) -> SurfaceRevision {
        var surface = try surface(id: surfaceID)
        try validate(destination, in: surface)
        let source = PixelRect(
            x: sourceX,
            y: sourceY,
            width: destination.width,
            height: destination.height
        )
        try validate(source, in: surface)
        let nextRevision = try advancedRevision(surface.revision)
        let nextMutationGeneration = try advancedRevision(surface.mutationGeneration)
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: PixelRect(
                x: 0,
                y: 0,
                width: surface.width,
                height: surface.height
            ),
            clips: nil
        )
        switch try await applyCanonicalMutation(
            to: surface,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration,
            mutation: .sameSurfaceCopy(
                region: region,
                destination: destination,
                source: source
            )
        ) {
        case let .committed(revision):
            return revision
        case .fallback, .notEligible:
            surface = try self.surface(id: surfaceID)
        }
        try prepareForMutation(&surface)
        copySurfacePixels(
            in: &surface,
            destination: destination,
            source: source
        )
        surface.revision = nextRevision
        surface.mutationGeneration = nextMutationGeneration
        surface.storage.recordDamage(destination, revision: surface.revision)
        currentFramePixelStorage[surfaceID] = nil
        surfaces[surfaceID] = surface
        recordDamage(destination)
        return surfaceRevision(of: surface)
    }

    @discardableResult
    package func drawCopy(
        surfaceID: UInt32,
        destination: PixelRect,
        bitmap: RawBitmap,
        source sourceRectangle: PixelRect? = nil
    ) async throws(RenderError) -> SurfaceRevision {
        try await acquireSurfaceOperation(surfaceID: surfaceID)
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }
        var surface = try surface(id: surfaceID)
        try validate(destination, in: surface)
        let source = sourceRectangle ?? PixelRect(
            x: 0,
            y: 0,
            width: bitmap.width,
            height: bitmap.height
        )
        guard source.width == destination.width, source.height == destination.height,
              bitmap.width > 0, bitmap.height > 0,
              source.x >= 0, source.y >= 0, source.width > 0, source.height > 0
        else {
            throw .invalidBitmap
        }
        let (sourceRight, sourceRightOverflow) = source.x.addingReportingOverflow(source.width)
        let (sourceBottom, sourceBottomOverflow) = source.y.addingReportingOverflow(source.height)
        guard !sourceRightOverflow, !sourceBottomOverflow,
              sourceRight <= bitmap.width, sourceBottom <= bitmap.height
        else {
            throw .invalidBitmap
        }
        let (minimumStride, strideOverflow) = bitmap.width.multipliedReportingOverflow(by: 4)
        guard !strideOverflow, bitmap.stride >= minimumStride else {
            throw .invalidBitmap
        }
        let (requiredBytes, sizeOverflow) = bitmap.stride.multipliedReportingOverflow(
            by: bitmap.height
        )
        guard !sizeOverflow, requiredBytes == bitmap.pixels.count else {
            throw .invalidBitmap
        }

        let nextRevision = try advancedRevision(surface.revision)
        let nextMutationGeneration = try advancedRevision(surface.mutationGeneration)
        let destinationBytesPerRow = surface.bytesPerRow
        let preservesAlpha = surface.format == .argb8888 && bitmap.format == .argb8888
        let fullSurface = PixelRect(
            x: 0,
            y: 0,
            width: surface.width,
            height: surface.height
        )
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: fullSurface,
            clips: nil
        )
        let allowsBootstrapDirectWrite: Bool
        switch try await applyCanonicalMutation(
            to: surface,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration,
            mutation: .bitmapCopy(
                region: region,
                destination: destination,
                bitmap: bitmap,
                source: source,
                preservesAlpha: preservesAlpha
            )
        ) {
        case let .committed(revision):
            return revision
        case .notEligible:
            allowsBootstrapDirectWrite = true
            surface = try self.surface(id: surfaceID)
        case .fallback:
            allowsBootstrapDirectWrite = false
            surface = try self.surface(id: surfaceID)
        }
        if allowsBootstrapDirectWrite,
           destination == fullSurface,
           var unified = surface.storage.unifiedBacking,
           let writable = unified.pool.checkoutWritable(
               namespace: unified.namespace,
               surfaceID: surfaceID,
               width: surface.width,
               height: surface.height,
               source: unified.current,
               allowsInPlaceSource: true
           ),
           writable.withLockedMutableBytes({ destinationBase, bytesPerRow in
               copyRawBitmap(
                   bitmap,
                   source: source,
                   to: destinationBase,
                   destinationBytesPerRow: bytesPerRow,
                   preservesAlpha: preservesAlpha
               )
           }) != nil,
           let committed = writable.finish(revision: nextRevision)
        {
            surface.revision = nextRevision
            surface.mutationGeneration = nextMutationGeneration
            unified.current = committed
            unified.damageJournal.clear()
            unified.damageHistory.reset(at: nextRevision)
            surface.storage.unifiedBacking = unified
            surface.storage.recordPublicationDamage(fullSurface)
            currentFramePixelStorage[surfaceID] = nil
            surfaces[surfaceID] = surface
            directIOSurfaceWriteBytes &+= UInt64(surface.width * surface.height * 4)
            recordDamage(fullSurface)
            return surfaceRevision(of: surface)
        }

        try prepareForMutation(&surface)
        surface.revision = nextRevision
        surface.mutationGeneration = nextMutationGeneration
        surface.pixels.withUnsafeMutableBytes { destinationBytes in
            guard let destinationBase = destinationBytes.baseAddress else { return }
            copyRawBitmap(
                bitmap,
                source: source,
                to: destinationBase.advanced(by: destination.y * destinationBytesPerRow
                    + destination.x * 4),
                destinationBytesPerRow: destinationBytesPerRow,
                preservesAlpha: preservesAlpha
            )
        }
        surface.storage.recordDamage(destination, revision: surface.revision)
        currentFramePixelStorage[surfaceID] = nil
        surfaces[surfaceID] = surface
        recordDamage(destination)
        return surfaceRevision(of: surface)
    }

    @discardableResult
    package func drawCopy(
        surfaceID: UInt32,
        destination: PixelRect,
        sourceSurfaceID: UInt32,
        source sourceRectangle: PixelRect
    ) async throws(RenderError) -> SurfaceRevision {
        if sourceSurfaceID == surfaceID {
            try await acquireSurfaceOperation(surfaceID: surfaceID)
            defer { releaseSurfaceOperation(surfaceID: surfaceID) }
            guard destination.width == sourceRectangle.width,
                  destination.height == sourceRectangle.height
            else {
                throw .invalidRectangle
            }
            return try await copyBitsUnlocked(
                surfaceID: surfaceID,
                destination: destination,
                sourceX: sourceRectangle.x,
                sourceY: sourceRectangle.y
            )
        }
        let operationSurfaceIDs = [surfaceID, sourceSurfaceID].sorted()
        var acquiredSurfaceIDs: [UInt32] = []
        do {
            for operationSurfaceID in operationSurfaceIDs {
                try await acquireSurfaceOperation(surfaceID: operationSurfaceID)
                acquiredSurfaceIDs.append(operationSurfaceID)
            }
        } catch {
            for operationSurfaceID in acquiredSurfaceIDs.reversed() {
                releaseSurfaceOperation(surfaceID: operationSurfaceID)
            }
            throw error
        }
        defer {
            for operationSurfaceID in acquiredSurfaceIDs.reversed() {
                releaseSurfaceOperation(surfaceID: operationSurfaceID)
            }
        }
        var destinationSurface = try surface(id: surfaceID)
        var sourceSurface = try surface(id: sourceSurfaceID)
        try validate(destination, in: destinationSurface)
        try validate(sourceRectangle, in: sourceSurface)
        guard destination.width == sourceRectangle.width,
              destination.height == sourceRectangle.height
        else {
            throw .invalidRectangle
        }
        let nextRevision = try advancedRevision(destinationSurface.revision)
        let nextMutationGeneration = try advancedRevision(
            destinationSurface.mutationGeneration
        )
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: PixelRect(
                x: 0,
                y: 0,
                width: destinationSurface.width,
                height: destinationSurface.height
            ),
            clips: nil
        )
        switch try await applyCanonicalCrossSurfaceCopy(
            destinationSurface: destinationSurface,
            sourceSurface: sourceSurface,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration,
            region: region,
            destination: destination,
            source: sourceRectangle
        ) {
        case let .committed(revision):
            return revision
        case .fallback, .notEligible:
            destinationSurface = try self.surface(id: surfaceID)
            sourceSurface = try self.surface(id: sourceSurfaceID)
        }
        try prepareForCrossSurfaceCopy(
            destination: &destinationSurface,
            source: &sourceSurface
        )
        copySurfacePixels(
            from: sourceSurface,
            to: &destinationSurface,
            destination: destination,
            source: sourceRectangle
        )
        destinationSurface.revision = nextRevision
        destinationSurface.mutationGeneration = nextMutationGeneration
        destinationSurface.storage.recordDamage(
            destination,
            revision: destinationSurface.revision
        )
        currentFramePixelStorage[surfaceID] = nil
        surfaces[surfaceID] = destinationSurface
        recordDamage(destination)
        return surfaceRevision(of: destinationSurface)
    }

    /// Applies one wire DRAW_FILL as one Surface transaction regardless of the
    /// canonical region's segment count.
    @discardableResult
    package func fill(
        surfaceID: UInt32,
        region: PixelRegion,
        colorARGB: UInt32
    ) async throws(RenderError) -> SurfaceRevision? {
        guard !region.isEmpty else { return nil }
        try await acquireSurfaceOperation(surfaceID: surfaceID)
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }

        var surface = try surface(id: surfaceID)
        for rectangle in region {
            try validate(rectangle, in: surface)
        }
        let nextRevision = try advancedRevision(surface.revision)
        let nextMutationGeneration = try advancedRevision(surface.mutationGeneration)
        let blue = UInt8(truncatingIfNeeded: colorARGB)
        let green = UInt8(truncatingIfNeeded: colorARGB >> 8)
        let red = UInt8(truncatingIfNeeded: colorARGB >> 16)
        let alpha = surface.format == .argb8888
            ? UInt8(truncatingIfNeeded: colorARGB >> 24)
            : 255
        let colorBGRA = UInt32(blue)
            | UInt32(green) << 8
            | UInt32(red) << 16
            | UInt32(alpha) << 24

        switch try await applyCanonicalMutation(
            to: surface,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration,
            mutation: .fill(region: region, colorBGRA: colorBGRA)
        ) {
        case let .committed(revision):
            recordMutationTransaction()
            return revision
        case .fallback, .notEligible:
            surface = try self.surface(id: surfaceID)
        }
        try prepareForMutation(&surface)
        for rectangle in region {
            fillPixels(in: &surface, rectangle: rectangle, colorBGRA: colorBGRA)
        }
        return commitRegionMutation(
            &surface,
            region: region,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration
        )
    }

    /// Applies one wire COPY_BITS as one Surface transaction. Segment order is
    /// chosen from the command-wide translation so overlapping same-Surface
    /// sources remain bit exact.
    @discardableResult
    package func copyBits(
        surfaceID: UInt32,
        region: PixelRegion,
        destination: PixelRect,
        sourceX: Int,
        sourceY: Int
    ) async throws(RenderError) -> SurfaceRevision? {
        guard !region.isEmpty else { return nil }
        try await acquireSurfaceOperation(surfaceID: surfaceID)
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }

        var surface = try surface(id: surfaceID)
        let source = PixelRect(
            x: sourceX,
            y: sourceY,
            width: destination.width,
            height: destination.height
        )
        for rectangle in region {
            try validate(rectangle, in: surface)
            let sourceRectangle = try translatedSource(
                for: rectangle,
                destination: destination,
                source: source
            )
            try validate(sourceRectangle, in: surface)
        }
        let nextRevision = try advancedRevision(surface.revision)
        let nextMutationGeneration = try advancedRevision(surface.mutationGeneration)

        switch try await applyCanonicalMutation(
            to: surface,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration,
            mutation: .sameSurfaceCopy(
                region: region,
                destination: destination,
                source: source
            )
        ) {
        case let .committed(revision):
            recordMutationTransaction()
            return revision
        case .fallback, .notEligible:
            surface = try self.surface(id: surfaceID)
        }
        try prepareForMutation(&surface)
        for rectangle in region.copyTraversal(source: source, destination: destination) {
            let sourceRectangle = translatedSourceAfterValidation(
                for: rectangle,
                destination: destination,
                source: source
            )
            copySurfacePixels(
                in: &surface,
                destination: rectangle,
                source: sourceRectangle
            )
        }
        return commitRegionMutation(
            &surface,
            region: region,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration
        )
    }

    /// Applies one bitmap DRAW_COPY as one Surface transaction.
    @discardableResult
    package func drawCopy(
        surfaceID: UInt32,
        region: PixelRegion,
        destination: PixelRect,
        bitmap: RawBitmap,
        source: PixelRect
    ) async throws(RenderError) -> SurfaceRevision? {
        guard !region.isEmpty else { return nil }
        try await acquireSurfaceOperation(surfaceID: surfaceID)
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }

        var surface = try surface(id: surfaceID)
        try validate(bitmap)
        for rectangle in region {
            try validate(rectangle, in: surface)
            let sourceRectangle = try translatedSource(
                for: rectangle,
                destination: destination,
                source: source
            )
            try validate(sourceRectangle, in: bitmap)
        }
        let nextRevision = try advancedRevision(surface.revision)
        let nextMutationGeneration = try advancedRevision(surface.mutationGeneration)
        let preservesAlpha = surface.format == .argb8888 && bitmap.format == .argb8888
        let fullSurface = PixelRect(
            x: 0,
            y: 0,
            width: surface.width,
            height: surface.height
        )
        let allowsBootstrapDirectWrite: Bool
        switch try await applyCanonicalMutation(
            to: surface,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration,
            mutation: .bitmapCopy(
                region: region,
                destination: destination,
                bitmap: bitmap,
                source: source,
                preservesAlpha: preservesAlpha
            )
        ) {
        case let .committed(revision):
            recordMutationTransaction()
            return revision
        case .notEligible:
            allowsBootstrapDirectWrite = true
            surface = try self.surface(id: surfaceID)
        case .fallback:
            allowsBootstrapDirectWrite = false
            surface = try self.surface(id: surfaceID)
        }
        if allowsBootstrapDirectWrite, region.singleRectangle == fullSurface {
            let fullSource = translatedSourceAfterValidation(
                for: fullSurface,
                destination: destination,
                source: source
            )
            if var unified = surface.storage.unifiedBacking,
               let writable = unified.pool.checkoutWritable(
                   namespace: unified.namespace,
                   surfaceID: surfaceID,
                   width: surface.width,
                   height: surface.height,
                   source: unified.current,
                   allowsInPlaceSource: true
               ),
               writable.withLockedMutableBytes({ destinationBase, bytesPerRow in
                   copyRawBitmap(
                       bitmap,
                       source: fullSource,
                       to: destinationBase,
                       destinationBytesPerRow: bytesPerRow,
                       preservesAlpha: preservesAlpha
                   )
               }) != nil,
               let committed = writable.finish(revision: nextRevision)
            {
                surface.revision = nextRevision
                surface.mutationGeneration = nextMutationGeneration
                unified.current = committed
                unified.damageJournal.clear()
                unified.damageHistory.reset(at: nextRevision)
                surface.storage.unifiedBacking = unified
                surface.storage.recordPublicationDamage(fullSurface)
                currentFramePixelStorage[surfaceID] = nil
                surfaces[surfaceID] = surface
                directIOSurfaceWriteBytes &+= UInt64(surface.width * surface.height * 4)
                recordDamage(fullSurface)
                recordMutationTransaction()
                return surfaceRevision(of: surface)
            }
        }

        try prepareForMutation(&surface)
        let destinationBytesPerRow = surface.bytesPerRow
        surface.pixels.withUnsafeMutableBytes { destinationBytes in
            guard let destinationBase = destinationBytes.baseAddress else { return }
            for rectangle in region {
                let sourceRectangle = translatedSourceAfterValidation(
                    for: rectangle,
                    destination: destination,
                    source: source
                )
                copyRawBitmap(
                    bitmap,
                    source: sourceRectangle,
                    to: destinationBase.advanced(
                        by: rectangle.y * destinationBytesPerRow + rectangle.x * 4
                    ),
                    destinationBytesPerRow: destinationBytesPerRow,
                    preservesAlpha: preservesAlpha
                )
            }
        }
        return commitRegionMutation(
            &surface,
            region: region,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration
        )
    }

    /// Applies one Surface-image DRAW_COPY as one transaction. Cross-Surface
    /// operations acquire both Surface locks in ID order before validation.
    @discardableResult
    package func drawCopy(
        surfaceID: UInt32,
        region: PixelRegion,
        destination: PixelRect,
        sourceSurfaceID: UInt32,
        source: PixelRect
    ) async throws(RenderError) -> SurfaceRevision? {
        guard !region.isEmpty else { return nil }
        if sourceSurfaceID == surfaceID {
            guard destination.width == source.width,
                  destination.height == source.height
            else {
                throw .invalidRectangle
            }
            return try await copyBits(
                surfaceID: surfaceID,
                region: region,
                destination: destination,
                sourceX: source.x,
                sourceY: source.y
            )
        }

        let operationSurfaceIDs = [surfaceID, sourceSurfaceID].sorted()
        var acquiredSurfaceIDs: [UInt32] = []
        do {
            for operationSurfaceID in operationSurfaceIDs {
                try await acquireSurfaceOperation(surfaceID: operationSurfaceID)
                acquiredSurfaceIDs.append(operationSurfaceID)
            }
        } catch {
            for operationSurfaceID in acquiredSurfaceIDs.reversed() {
                releaseSurfaceOperation(surfaceID: operationSurfaceID)
            }
            throw error
        }
        defer {
            for operationSurfaceID in acquiredSurfaceIDs.reversed() {
                releaseSurfaceOperation(surfaceID: operationSurfaceID)
            }
        }

        var destinationSurface = try surface(id: surfaceID)
        var sourceSurface = try surface(id: sourceSurfaceID)
        for rectangle in region {
            try validate(rectangle, in: destinationSurface)
            let sourceRectangle = try translatedSource(
                for: rectangle,
                destination: destination,
                source: source
            )
            try validate(sourceRectangle, in: sourceSurface)
        }
        let nextRevision = try advancedRevision(destinationSurface.revision)
        let nextMutationGeneration = try advancedRevision(
            destinationSurface.mutationGeneration
        )
        switch try await applyCanonicalCrossSurfaceCopy(
            destinationSurface: destinationSurface,
            sourceSurface: sourceSurface,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration,
            region: region,
            destination: destination,
            source: source
        ) {
        case let .committed(revision):
            recordMutationTransaction()
            return revision
        case .fallback, .notEligible:
            destinationSurface = try self.surface(id: surfaceID)
            sourceSurface = try self.surface(id: sourceSurfaceID)
        }
        try prepareForCrossSurfaceCopy(
            destination: &destinationSurface,
            source: &sourceSurface
        )
        for rectangle in region {
            let sourceRectangle = translatedSourceAfterValidation(
                for: rectangle,
                destination: destination,
                source: source
            )
            copySurfacePixels(
                from: sourceSurface,
                to: &destinationSurface,
                destination: rectangle,
                source: sourceRectangle
            )
        }
        return commitRegionMutation(
            &destinationSurface,
            region: region,
            revision: nextRevision,
            mutationGeneration: nextMutationGeneration
        )
    }

    @discardableResult
    package func drawScaledCopy(
        surfaceID: UInt32,
        destination: PixelRect,
        bitmap: RawBitmap,
        source: PixelRect,
        clippedDestinations: [PixelRect],
        expectedMutationBarrier: SurfaceMutationBarrier? = nil,
        videoSequence: SurfaceVideoSequence? = nil
    ) async throws(RenderError) -> SurfaceRevision? {
        try await acquireSurfaceOperation(surfaceID: surfaceID)
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }
        var surface = try surface(id: surfaceID)
        if let expectedMutationBarrier,
           mutationBarrier(of: surface) != expectedMutationBarrier
        {
            return nil
        }
        if let videoSequence, !canCommit(videoSequence, to: surface) {
            return nil
        }
        try validate(destination, in: surface)
        guard source.x >= 0, source.y >= 0,
              source.width > 0, source.height > 0,
              bitmap.width > 0, bitmap.height > 0
        else {
            throw .invalidBitmap
        }
        let (sourceRight, sourceRightOverflow) = source.x.addingReportingOverflow(source.width)
        let (sourceBottom, sourceBottomOverflow) = source.y.addingReportingOverflow(source.height)
        guard !sourceRightOverflow, !sourceBottomOverflow,
              sourceRight <= bitmap.width, sourceBottom <= bitmap.height
        else {
            throw .invalidBitmap
        }
        let (minimumStride, strideOverflow) = bitmap.width.multipliedReportingOverflow(by: 4)
        let (requiredBytes, sizeOverflow) = bitmap.stride.multipliedReportingOverflow(
            by: bitmap.height
        )
        guard !strideOverflow, !sizeOverflow,
              bitmap.stride >= minimumStride,
              requiredBytes == bitmap.pixels.count
        else {
            throw .invalidBitmap
        }
        let (_, horizontalScaleOverflow) = (destination.width - 1)
            .multipliedReportingOverflow(by: source.width)
        let (_, verticalScaleOverflow) = (destination.height - 1)
            .multipliedReportingOverflow(by: source.height)
        guard !horizontalScaleOverflow, !verticalScaleOverflow else {
            throw .integerOverflow
        }
        for clipped in clippedDestinations {
            try validate(clipped, in: surface)
            guard clipped.x >= destination.x, clipped.y >= destination.y,
                  clipped.x + clipped.width <= destination.x + destination.width,
                  clipped.y + clipped.height <= destination.y + destination.height
            else {
                throw .invalidRectangle
            }
        }
        guard !clippedDestinations.isEmpty else {
            return nil
        }

        let nextRevision = try advancedRevision(surface.revision)
        try prepareForMutation(&surface)
        surface.revision = nextRevision
        if let videoSequence {
            surface.latestVideoSequence = videoSequence.value
        }
        let destinationBytesPerRow = surface.bytesPerRow
        let preservesAlpha = surface.format == .argb8888 && bitmap.format == .argb8888
        surface.pixels.withUnsafeMutableBytes { destinationBytes in
            bitmap.pixels.withUnsafeBytes { sourceBytes in
                guard let destinationBase = destinationBytes.baseAddress,
                      let sourceBase = sourceBytes.baseAddress
                else {
                    return
                }
                for clipped in clippedDestinations {
                    for destinationY in clipped.y..<(clipped.y + clipped.height) {
                        let sourceY = source.y
                            + (destinationY - destination.y) * source.height / destination.height
                        let sourceRow = bitmap.topDown
                            ? sourceY
                            : bitmap.height - 1 - sourceY
                        for destinationX in clipped.x..<(clipped.x + clipped.width) {
                            let sourceX = source.x
                                + (destinationX - destination.x) * source.width / destination.width
                            let sourcePixel = sourceBase.advanced(
                                by: sourceRow * bitmap.stride + sourceX * 4
                            )
                            let destinationPixel = destinationBase.advanced(
                                by: destinationY * destinationBytesPerRow + destinationX * 4
                            )
                            let sourceBGRA = sourcePixel.loadUnaligned(as: UInt32.self)
                            destinationPixel.storeBytes(
                                of: preservesAlpha ? sourceBGRA : sourceBGRA | 0xff00_0000,
                                as: UInt32.self
                            )
                        }
                    }
                }
            }
        }
        for clipped in clippedDestinations {
            surface.storage.recordDamage(clipped, revision: surface.revision)
            recordDamage(clipped)
        }
        currentFramePixelStorage[surfaceID] = nil
        surfaces[surfaceID] = surface
        return surfaceRevision(of: surface)
    }

    /// Transactionally composites an opaque decoder frame into a writable
    /// IOSurface candidate. The candidate becomes canonical only after every
    /// Metal command has completed successfully.
    @discardableResult
    package func drawNativeVideoFrame(
        surfaceID: UInt32,
        destination: PixelRect,
        frame: any SpiceDecodedVideoFrame,
        source: PixelRect,
        topDown: Bool,
        clippedDestinations: [PixelRect],
        isAdvancedVideo: Bool = false,
        expectedMutationBarrier: SurfaceMutationBarrier? = nil,
        videoSequence: SurfaceVideoSequence? = nil
    ) async throws(SurfaceVideoCompositionError) -> SurfaceRevision? {
        guard let compositor = metalCompositor else {
            throw videoFallback(metalCompositorInitializationError ?? .unsupportedDevice)
        }
        do {
            try await acquireSurfaceOperation(surfaceID: surfaceID)
        } catch let error {
            throw .render(error)
        }
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }
        guard let surface = surfaces[surfaceID] else {
            throw .staleSurface
        }
        if let expectedMutationBarrier,
           mutationBarrier(of: surface) != expectedMutationBarrier
        {
            throw .staleSurface
        }
        if let videoSequence, !canCommit(videoSequence, to: surface) {
            throw .staleSurface
        }
        do {
            try validate(destination, in: surface)
            let (sourceRight, sourceRightOverflow) = source.x.addingReportingOverflow(
                source.width
            )
            let (sourceBottom, sourceBottomOverflow) = source.y.addingReportingOverflow(
                source.height
            )
            guard source.x >= 0, source.y >= 0,
                  source.width > 0, source.height > 0,
                  !sourceRightOverflow, !sourceBottomOverflow,
                  sourceRight <= frame.width,
                  sourceBottom <= frame.height
            else {
                throw RenderError.invalidBitmap
            }
            let destinationRight = destination.x + destination.width
            let destinationBottom = destination.y + destination.height
            for clipped in clippedDestinations {
                try validate(clipped, in: surface)
                let clippedRight = clipped.x + clipped.width
                let clippedBottom = clipped.y + clipped.height
                guard clipped.x >= destination.x,
                      clipped.y >= destination.y,
                      clippedRight <= destinationRight,
                      clippedBottom <= destinationBottom
                else {
                    throw RenderError.invalidRectangle
                }
            }
        } catch let error as RenderError {
            throw .render(error)
        } catch {
            throw .render(.invalidRectangle)
        }
        guard !clippedDestinations.isEmpty else {
            return nil
        }
        guard let unified = surface.storage.unifiedBacking else {
            throw videoFallback(.unsupportedDevice)
        }
        let requested = surfaceRevision(of: surface)
        guard let writable = unified.pool.checkoutWritable(
            namespace: unified.namespace,
            surfaceID: surfaceID,
            width: surface.width,
            height: surface.height,
            source: unified.current
        ) else {
            poolExhaustions &+= 1
            throw videoFallback(
                .invalidDestination("revisioned IOSurface pool is exhausted")
            )
        }

        let fullSurface = PixelRect(
            x: 0,
            y: 0,
            width: surface.width,
            height: surface.height
        )
        let overwritesFullSurface = destination == fullSurface
            && clippedDestinations == [fullSurface]
        var uploadedBytes: UInt64 = 0
        if !overwritesFullSurface {
            let synchronizesRevision = unified.current != nil
            guard await writable.synchronizeFromSource() else {
                revisionedGPUErrors &+= 1
                nativeVideoFallbacks &+= 1
                throw .compositor(
                    .commandExecutionFailed("candidate revision synchronization failed")
                )
            }
            if synchronizesRevision {
                gpuCopyBytes &+= UInt64(surface.width * surface.height * 4)
            }
            guard isCurrent(requested) else {
                throw .staleSurface
            }

            if !unified.damageJournal.isEmpty {
                let rectangles = unified.damageJournal.copyRectangles.map {
                    IOSurfaceCopyRectangle(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                }
                guard let copiedBytes = writable.copyPackedPixels(
                    surface.pixels,
                    sourceBytesPerRow: surface.bytesPerRow,
                    rectangles: rectangles
                ) else {
                    throw videoFallback(.destinationTextureMappingFailed)
                }
                uploadedBytes = copiedBytes
            }
        }

        let destinationSurface = writable.withIOSurface { $0 }
        let metalSource = SpiceMetalVideoRectangle(
            x: source.x,
            y: source.y,
            width: source.width,
            height: source.height
        )
        let metalDestination = SpiceMetalVideoRectangle(
            x: destination.x,
            y: destination.y,
            width: destination.width,
            height: destination.height
        )
        do {
            compositorAttempt &+= 1
            if let injectedError = compositorFailureForAttempt(compositorAttempt) {
                throw videoFallback(injectedError)
            }
            try await compositor.composite(
                frame: frame,
                sourceRect: metalSource,
                orientation: topDown ? .topDown : .bottomUp,
                into: destinationSurface,
                destinationRect: metalDestination,
                clips: clippedDestinations.map { clipped in
                    SpiceMetalVideoRectangle(
                        x: clipped.x,
                        y: clipped.y,
                        width: clipped.width,
                        height: clipped.height
                    )
                }
            )
            guard isCurrent(requested) else {
                throw SurfaceVideoCompositionError.staleSurface
            }
        } catch let error as SurfaceVideoCompositionError {
            throw error
        } catch let error as SpiceMetalCompositorError {
            throw videoFallback(error)
        } catch {
            throw videoFallback(.commandExecutionFailed(String(describing: error)))
        }

        let nextRevision: UInt64
        do {
            nextRevision = try advancedRevision(surface.revision)
        } catch {
            throw .render(error)
        }
        guard isCurrent(requested),
              let committedRevision = writable.finish(revision: nextRevision),
              var liveSurface = surfaces[surfaceID],
              liveSurface.lifecycleGeneration == surface.lifecycleGeneration,
              liveSurface.revision == surface.revision,
              var liveUnified = liveSurface.storage.unifiedBacking
        else {
            throw .staleSurface
        }

        liveSurface.revision = nextRevision
        if let videoSequence {
            liveSurface.latestVideoSequence = videoSequence.value
        }
        if isAdvancedVideo {
            liveSurface.latestAdvancedVideoRevision = nextRevision
        }
        liveUnified.current = committedRevision
        liveUnified.damageJournal.clear()
        liveUnified.damageHistory.reset(at: nextRevision)
        liveSurface.storage.unifiedBacking = liveUnified
        for clipped in clippedDestinations {
            liveSurface.storage.recordPublicationDamage(clipped)
        }
        currentFramePixelStorage[surfaceID] = nil
        surfaces[surfaceID] = liveSurface
        if uploadedBytes > 0 {
            if unified.damageJournal.isFullFrame {
                fullFrameCopyBytes &+= uploadedBytes
            } else {
                partialFrameCopyBytes &+= uploadedBytes
            }
        }
        for clipped in clippedDestinations {
            recordDamage(clipped)
        }
        nativeVideoFrames &+= 1
        return surfaceRevision(of: liveSurface)
    }

    package func snapshot(surfaceID: UInt32) async throws(RenderError) -> FrameSnapshot {
        guard !rejectsNewOperations else {
            throw .storeClosed
        }
        while true {
            guard !Task.isCancelled else {
                throw .operationCancelled
            }
            let surface = try surface(id: surfaceID)
            if let snapshot = await makeSnapshot(
                from: surface,
                matching: surfaceRevision(of: surface)
            ) {
                return snapshot
            }
        }
    }

    /// Returns a frame only when the requested lifecycle and content revision
    /// are still current. Use this when the caller requires exact identity;
    /// display publication uses `snapshot(atLeast:)` so a newer immutable frame
    /// can safely satisfy an older request.
    package func snapshot(matching requested: SurfaceRevision) async -> FrameSnapshot? {
        guard !Task.isCancelled,
              !rejectsNewOperations,
              let surface = surfaces[requested.surfaceID],
              surface.lifecycleGeneration == requested.lifecycleGeneration,
              surface.revision == requested.revision
        else {
            return nil
        }
        return await makeSnapshot(from: surface, matching: requested)
    }

    /// Returns a frame from the requested lifecycle whose content includes at
    /// least the requested revision. The per-surface operation reservation is
    /// held while selecting and constructing the candidate, so concurrent
    /// draws cannot make the snapshot chase a moving exact revision.
    package func snapshot(atLeast requested: SurfaceRevision) async -> FrameSnapshot? {
        guard !Task.isCancelled,
              !rejectsNewOperations,
              let eligible = surfaces[requested.surfaceID],
              eligible.lifecycleGeneration == requested.lifecycleGeneration,
              eligible.revision >= requested.revision
        else {
            return nil
        }
        do {
            try await acquireSurfaceOperation(surfaceID: requested.surfaceID)
        } catch {
            return nil
        }
        defer { releaseSurfaceOperation(surfaceID: requested.surfaceID) }
        guard !Task.isCancelled,
              let surface = surfaces[requested.surfaceID],
              surface.lifecycleGeneration == requested.lifecycleGeneration,
              surface.revision >= requested.revision
        else {
            return nil
        }
        return await makeSnapshot(
            from: surface,
            matching: surfaceRevision(of: surface),
            surfaceOperationAlreadyAcquired: true
        )
    }

    /// Creates the immutable frame used by desktop presentation and atomically
    /// transfers all canonical damage accumulated since the previous
    /// publication. Hidden desktops never call this method, so their damage is
    /// retained and bounded until visibility returns.
    package func publicationSnapshot(
        atLeast requested: SurfaceRevision
    ) async -> FrameSnapshot? {
        guard !Task.isCancelled,
              !rejectsNewOperations,
              let eligible = surfaces[requested.surfaceID],
              eligible.lifecycleGeneration == requested.lifecycleGeneration,
              eligible.revision >= requested.revision
        else {
            return nil
        }
        do {
            try await acquireSurfaceOperation(surfaceID: requested.surfaceID)
        } catch {
            return nil
        }
        defer { releaseSurfaceOperation(surfaceID: requested.surfaceID) }
        guard !Task.isCancelled,
              let surface = surfaces[requested.surfaceID],
              surface.lifecycleGeneration == requested.lifecycleGeneration,
              surface.revision >= requested.revision
        else {
            return nil
        }
        let publicationRevision = surfaceRevision(of: surface)
        let damage = surface.storage.publicationDamageJournal
        guard let snapshot = await makeSnapshot(
            from: surface,
            matching: publicationRevision,
            surfaceOperationAlreadyAcquired: true
        ),
            !Task.isCancelled,
            var liveSurface = surfaces[requested.surfaceID],
            liveSurface.lifecycleGeneration == snapshot.lifecycleGeneration,
            liveSurface.revision == snapshot.revision
        else {
            return nil
        }
        liveSurface.storage.publicationDamageJournal.clear()
        surfaces[requested.surfaceID] = liveSurface
        guard !damage.isEmpty else {
            return snapshot.withPublicationDamage(damage)
        }
        let damageLease = SurfacePublicationDamageLease { [weak self] in
            await self?.restorePublicationDamage(
                damage,
                matching: publicationRevision
            )
        }
        return snapshot.withPublicationDamage(damage, lease: damageLease)
    }

    package func descriptor(surfaceID: UInt32) throws(RenderError) -> SurfaceDescriptor {
        guard !rejectsNewOperations else {
            throw .storeClosed
        }
        let surface = try surface(id: surfaceID)
        return SurfaceDescriptor(
            surfaceID: surface.id,
            width: surface.width,
            height: surface.height,
            bytesPerRow: surface.bytesPerRow,
            format: surface.format,
            lifecycleGeneration: surface.lifecycleGeneration,
            revision: surface.revision,
            mutationGeneration: surface.mutationGeneration
        )
    }

    package func metrics() -> SurfaceStoreMetrics {
        let materializations = materializationMetrics.snapshot()
        let poolMetrics = framePool.metrics()
        let revisionedMetrics = revisionedFramePool?.metrics()
        return SurfaceStoreMetrics(
            mutationTransactions: mutationTransactions,
            temporaryCopyBytes: temporaryCopyBytes,
            bulkCopyCalls: bulkCopyCalls,
            rowCopyCalls: rowCopyCalls,
            fillKernelCalls: fillKernelCalls,
            damageOperations: damageOperations,
            damageBytes: damageBytes,
            snapshots: snapshots,
            fullFrameCopyBytes: fullFrameCopyBytes,
            partialFrameCopyBytes: partialFrameCopyBytes,
            directIOSurfaceWriteBytes: directIOSurfaceWriteBytes,
            cpuMaterializations: materializations.count,
            cpuMaterializationBytes: materializations.bytes,
            poolExhaustions: poolExhaustions,
            inFlightLeases: poolMetrics.inUseFrames
                + (revisionedMetrics?.inFlightLeases ?? 0),
            revisionedBackingEnabled: revisionedFramePool != nil,
            revisionedAllocatedFrames: revisionedMetrics?.allocatedFrames ?? 0,
            revisionedAllocatedBytes: revisionedMetrics?.allocatedBytes ?? 0,
            gpuCopyBytes: gpuCopyBytes,
            gpuErrors: revisionedGPUErrors &+ compositorErrors,
            compositorErrors: compositorErrors,
            recommendedMaximumWorkingSetSize:
                revisionedMetrics?.recommendedMaximumWorkingSetSize ?? 0,
            currentMetalAllocatedSize: revisionedMetrics?.currentMetalAllocatedSize ?? 0,
            nativeVideoFrames: nativeVideoFrames,
            nativeVideoFallbacks: nativeVideoFallbacks
        )
    }

    package func surfaceOperationReservationDiagnostics()
        -> SurfaceOperationReservationDiagnostics
    {
        var waitingCount = 0
        var grantedWaiterCount = 0
        for reservation in surfaceOperationReservations.values {
            switch reservation {
            case .queued:
                waitingCount += 1
            case .granted, .cancelledAfterGrant:
                grantedWaiterCount += 1
            }
        }
        return SurfaceOperationReservationDiagnostics(
            activeSurfaceCount: activeSurfaceOperations.count,
            waitingCount: waitingCount,
            grantedWaiterCount: grantedWaiterCount,
            reservedCount: reservedSurfaceOperationReservationIDs.count
        )
    }

    /// Package-only deterministic ownership seam. The production reservation
    /// path remains unchanged; tests can hold one Surface lease across an
    /// explicit suspension without relying on renderer or hardware timing.
    package func withSurfaceOperationForTesting(
        surfaceID: UInt32,
        operation: @escaping @Sendable () async -> Void
    ) async throws(RenderError) {
        try await acquireSurfaceOperation(surfaceID: surfaceID)
        defer { releaseSurfaceOperation(surfaceID: surfaceID) }
        await operation()
    }

    private func makeSnapshot(
        from surface: Surface,
        matching requested: SurfaceRevision,
        surfaceOperationAlreadyAcquired: Bool = false
    ) async -> FrameSnapshot? {
        guard !Task.isCancelled else { return nil }
        guard let unified = surface.storage.unifiedBacking else {
            guard isCurrent(requested) else {
                return nil
            }
            return makeDataBackendSnapshot(from: surface)
        }

        if unified.damageJournal.isEmpty,
           let current = unified.current,
           current.revision == surface.revision,
           let snapshot = makeRevisionedSnapshot(from: surface, revision: current)
        {
            guard isCurrent(requested) else {
                return nil
            }
            snapshots &+= 1
            return snapshot
        }

        var acquiredSurfaceOperation = false
        if !surfaceOperationAlreadyAcquired {
            do {
                try await acquireSurfaceOperation(surfaceID: surface.id)
                acquiredSurfaceOperation = true
            } catch {
                return nil
            }
        }
        defer {
            if acquiredSurfaceOperation {
                releaseSurfaceOperation(surfaceID: surface.id)
            }
        }
        guard !Task.isCancelled,
              let operationSurface = surfaces[surface.id],
              operationSurface.lifecycleGeneration == requested.lifecycleGeneration,
              operationSurface.revision == requested.revision,
              let operationUnified = operationSurface.storage.unifiedBacking
        else {
            return nil
        }
        if operationUnified.damageJournal.isEmpty,
           let current = operationUnified.current,
           current.revision == operationSurface.revision,
           let snapshot = makeRevisionedSnapshot(
               from: operationSurface,
               revision: current
           )
        {
            snapshots &+= 1
            return snapshot
        }

        guard !Task.isCancelled,
              let writable = operationUnified.pool.checkoutWritable(
            namespace: operationUnified.namespace,
            surfaceID: operationSurface.id,
            width: operationSurface.width,
            height: operationSurface.height,
            source: operationUnified.current,
            allowsInPlaceSource: true
        ) else {
            guard isCurrent(requested) else {
                return nil
            }
            poolExhaustions &+= 1
            snapshots &+= 1
            return makeSnapshot(
                from: operationSurface,
                ioSurfaceFrame: nil,
                pixels: operationSurface.pixels
            )
        }

        let catchUpJournal = operationUnified.damageHistory.catchUpJournal(
            from: writable.destinationRevision,
            pending: operationUnified.damageJournal
        )
        let rectangles = catchUpJournal.copyRectangles.map {
            IOSurfaceCopyRectangle(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        guard !Task.isCancelled,
              let copiedBytes = writable.copyPackedPixels(
            operationSurface.pixels,
            sourceBytesPerRow: operationSurface.bytesPerRow,
            rectangles: rectangles
        ) else {
            disableUnifiedBacking(for: requested.surfaceID, matching: requested)
            snapshots &+= 1
            return makeSnapshot(
                from: operationSurface,
                ioSurfaceFrame: nil,
                pixels: operationSurface.pixels
            )
        }
        guard !Task.isCancelled,
              isCurrent(requested),
              let committed = writable.finish(revision: operationSurface.revision),
              var liveSurface = surfaces[operationSurface.id],
              liveSurface.lifecycleGeneration == operationSurface.lifecycleGeneration,
              liveSurface.revision == operationSurface.revision,
              var liveUnified = liveSurface.storage.unifiedBacking
        else {
            return nil
        }

        liveUnified.current = committed
        liveUnified.damageHistory.commit(
            operationUnified.damageJournal,
            revision: operationSurface.revision
        )
        liveUnified.damageJournal.clear()
        liveSurface.storage.unifiedBacking = liveUnified
        surfaces[operationSurface.id] = liveSurface
        if catchUpJournal.isFullFrame {
            fullFrameCopyBytes &+= copiedBytes
        } else {
            partialFrameCopyBytes &+= copiedBytes
        }
        guard let snapshot = makeRevisionedSnapshot(
            from: liveSurface,
            revision: committed
        ) else {
            return nil
        }
        snapshots &+= 1
        return snapshot
    }

    private func restorePublicationDamage(
        _ damage: SurfaceDamageJournal,
        matching revision: SurfaceRevision
    ) async {
        guard !damage.isEmpty else { return }
        // Restoration owns the same per-Surface serialization as mutation and
        // close. It is unconditional because cancellation is precisely why the
        // publication ownership is returning to the store.
        await acquireSurfaceOperationUnconditionally(surfaceID: revision.surfaceID)
        defer { releaseSurfaceOperation(surfaceID: revision.surfaceID) }
        guard var surface = surfaces[revision.surfaceID],
              surface.lifecycleGeneration == revision.lifecycleGeneration
        else {
            return
        }
        surface.storage.publicationDamageJournal.merge(damage)
        surfaces[revision.surfaceID] = surface
    }

    private func makeDataBackendSnapshot(from surface: Surface) -> FrameSnapshot {
        let ioSurfaceFrame = framePool.makeFrame(
            width: surface.width,
            height: surface.height,
            sourceBytesPerRow: surface.bytesPerRow,
            pixels: surface.pixels
        )
        snapshots &+= 1
        if ioSurfaceFrame == nil {
            poolExhaustions &+= 1
        } else {
            fullFrameCopyBytes &+= UInt64(surface.pixels.count)
        }
        return makeSnapshot(
            from: surface,
            ioSurfaceFrame: ioSurfaceFrame,
            pixels: ioSurfaceFrame == nil ? surface.pixels : nil
        )
    }

    private func makeRevisionedSnapshot(
        from surface: Surface,
        revision current: RevisionedIOSurfaceRevision
    ) -> FrameSnapshot? {
        let requested = surfaceRevision(of: surface)
        if let cached = currentFramePixelStorage[surface.id],
           cached.revision == requested,
           let ioSurfaceFrame = cached.storage.backingIOSurfaceFrame
        {
            return FrameSnapshot(
                surfaceID: surface.id,
                width: surface.width,
                height: surface.height,
                bytesPerRow: surface.bytesPerRow,
                lifecycleGeneration: surface.lifecycleGeneration,
                revision: surface.revision,
                pixelStorage: cached.storage,
                ioSurfaceFrame: ioSurfaceFrame,
                isAdvancedVideoFrame: surface.latestAdvancedVideoRevision == surface.revision
            )
        }
        guard let ioSurfaceFrame = current.makeLease() else {
            return nil
        }
        let storage = FramePixelStorage(
            pixels: nil,
            ioSurfaceFrame: ioSurfaceFrame,
            expectedPixelBytes: surface.width * surface.height * 4,
            materializationMetrics: materializationMetrics
        )
        currentFramePixelStorage[surface.id] = (requested, storage)
        return FrameSnapshot(
            surfaceID: surface.id,
            width: surface.width,
            height: surface.height,
            bytesPerRow: surface.bytesPerRow,
            lifecycleGeneration: surface.lifecycleGeneration,
            revision: surface.revision,
            pixelStorage: storage,
            ioSurfaceFrame: ioSurfaceFrame,
            isAdvancedVideoFrame: surface.latestAdvancedVideoRevision == surface.revision
        )
    }

    private func makeSnapshot(
        from surface: Surface,
        ioSurfaceFrame: IOSurfaceFrame?,
        pixels: consuming Data?
    ) -> FrameSnapshot {
        let snapshotPixels = pixels.map { source in
            source.withUnsafeBytes { Data($0) }
        }
        if let snapshotPixels {
            fullFrameCopyBytes &+= UInt64(snapshotPixels.count)
        }
        return FrameSnapshot(
            surfaceID: surface.id,
            width: surface.width,
            height: surface.height,
            bytesPerRow: surface.bytesPerRow,
            lifecycleGeneration: surface.lifecycleGeneration,
            revision: surface.revision,
            pixels: snapshotPixels,
            ioSurfaceFrame: ioSurfaceFrame,
            materializationMetrics: materializationMetrics,
            isAdvancedVideoFrame: surface.latestAdvancedVideoRevision == surface.revision
        )
    }

    private func surfaceRevision(of surface: Surface) -> SurfaceRevision {
        SurfaceRevision(
            surfaceID: surface.id,
            lifecycleGeneration: surface.lifecycleGeneration,
            revision: surface.revision
        )
    }

    private func mutationBarrier(of surface: Surface) -> SurfaceMutationBarrier {
        SurfaceMutationBarrier(
            surfaceID: surface.id,
            lifecycleGeneration: surface.lifecycleGeneration,
            generation: surface.mutationGeneration
        )
    }

    private func canCommit(_ sequence: SurfaceVideoSequence, to surface: Surface) -> Bool {
        sequence.surfaceID == surface.id
            && sequence.lifecycleGeneration == surface.lifecycleGeneration
            && sequence.value > surface.latestVideoSequence
    }

    private func isCurrent(_ requested: SurfaceRevision) -> Bool {
        guard let surface = surfaces[requested.surfaceID] else {
            return false
        }
        return surface.lifecycleGeneration == requested.lifecycleGeneration
            && surface.revision == requested.revision
    }

    private func disableUnifiedBacking(
        for surfaceID: UInt32,
        matching requested: SurfaceRevision
    ) {
        guard var surface = surfaces[surfaceID],
              surface.lifecycleGeneration == requested.lifecycleGeneration,
              surface.revision == requested.revision
        else {
            return
        }
        surface.storage.disableUnifiedBacking(surfaceID: surfaceID)
        currentFramePixelStorage[surfaceID] = nil
        surfaces[surfaceID] = surface
    }

    private func videoFallback(
        _ error: SpiceMetalCompositorError
    ) -> SurfaceVideoCompositionError {
        nativeVideoFallbacks &+= 1
        switch error {
        case .unsupportedDevice, .unsupportedPixelFormat, .unsupportedColorMatrix,
             .unsupportedColorRange, .unsupportedGeometry, .invalidSourceRectangle,
             .invalidDestination:
            break
        case .shaderLibraryUnavailable, .pipelineCreationFailed, .commandQueueUnavailable,
             .sourceTextureMappingFailed, .destinationTextureMappingFailed,
             .commandBufferUnavailable, .commandEncoderUnavailable,
             .commandExecutionFailed:
            compositorErrors &+= 1
        }
        return .compositor(error)
    }

    private func acquireSurfaceOperation(
        surfaceID: UInt32
    ) async throws(RenderError) {
        guard !rejectsNewOperations else {
            throw .storeClosed
        }
        guard await acquireSurfaceOperationCancellably(surfaceID: surfaceID) else {
            throw .operationCancelled
        }
        guard !Task.isCancelled else {
            releaseSurfaceOperation(surfaceID: surfaceID)
            throw .operationCancelled
        }
        guard !rejectsNewOperations else {
            releaseSurfaceOperation(surfaceID: surfaceID)
            throw .storeClosed
        }
    }

    private func acquireSurfaceOperationUnconditionally(surfaceID: UInt32) async {
        if activeSurfaceOperations.insert(surfaceID).inserted {
            return
        }
        let reservationID = reserveSurfaceOperationReservationID()
        await surfaceOperationWaiterWillRegister?(surfaceID, reservationID)
        let outcome = await withCheckedContinuation { continuation in
            registerSurfaceOperationWaiter(
                surfaceID: surfaceID,
                reservationID: reservationID,
                continuation: continuation,
                isCancelled: false
            )
        }
        guard case .acquired = outcome else { return }
        await surfaceOperationGrantWillBeClaimed?(surfaceID, reservationID)
        _ = claimSurfaceOperationReservation(
            reservationID,
            cancellationRequested: false
        )
    }

    private func acquireSurfaceOperationCancellably(surfaceID: UInt32) async -> Bool {
        if activeSurfaceOperations.insert(surfaceID).inserted {
            guard !Task.isCancelled else {
                releaseSurfaceOperation(surfaceID: surfaceID)
                return false
            }
            return true
        }

        let reservationID = reserveSurfaceOperationReservationID()
        let cancellation = SurfaceOperationCancellation()
        return await withTaskCancellationHandler {
            await surfaceOperationWaiterWillRegister?(surfaceID, reservationID)
            let outcome = await withCheckedContinuation { continuation in
                registerSurfaceOperationWaiter(
                    surfaceID: surfaceID,
                    reservationID: reservationID,
                    continuation: continuation,
                    isCancelled: cancellation.isCancelled || Task.isCancelled
                )
            }
            guard case .acquired = outcome else { return false }
            await surfaceOperationGrantWillBeClaimed?(surfaceID, reservationID)
            return claimSurfaceOperationReservation(
                reservationID,
                cancellationRequested: cancellation.isCancelled || Task.isCancelled
            )
        } onCancel: {
            cancellation.cancel()
            Task { [weak self] in
                await self?.cancelSurfaceOperationReservation(reservationID)
            }
        }
    }

    private func registerSurfaceOperationWaiter(
        surfaceID: UInt32,
        reservationID: UInt64,
        continuation: CheckedContinuation<SurfaceOperationWaitOutcome, Never>,
        isCancelled: Bool
    ) {
        guard !isCancelled else {
            reservedSurfaceOperationReservationIDs.remove(reservationID)
            continuation.resume(returning: .cancelled)
            return
        }
        // The observer above is an intentional suspension point. The holder
        // that made this caller wait may have released while the actor was
        // reentrant, so registration must atomically recheck ownership instead
        // of appending a waiter that no future release could wake.
        if activeSurfaceOperations.insert(surfaceID).inserted {
            surfaceOperationReservations[reservationID] = .granted(
                surfaceID: surfaceID
            )
            continuation.resume(returning: .acquired)
            return
        }
        surfaceOperationReservations[reservationID] = .queued(
            surfaceID: surfaceID,
            continuation: continuation
        )
        surfaceOperationWaiters[surfaceID, default: []].append(reservationID)
    }

    private func cancelSurfaceOperationReservation(_ reservationID: UInt64) {
        guard let reservation = surfaceOperationReservations[reservationID] else {
            return
        }
        switch reservation {
        case let .queued(surfaceID, continuation):
            surfaceOperationReservations.removeValue(forKey: reservationID)
            reservedSurfaceOperationReservationIDs.remove(reservationID)
            if var waiters = surfaceOperationWaiters[surfaceID],
               let index = waiters.firstIndex(of: reservationID)
            {
                waiters.remove(at: index)
                surfaceOperationWaiters[surfaceID] = waiters.isEmpty ? nil : waiters
            }
            continuation.resume(returning: .cancelled)
        case let .granted(surfaceID):
            surfaceOperationReservations[reservationID] =
                .cancelledAfterGrant(surfaceID: surfaceID)
        case .cancelledAfterGrant:
            break
        }
    }

    private func claimSurfaceOperationReservation(
        _ reservationID: UInt64,
        cancellationRequested: Bool
    ) -> Bool {
        reservedSurfaceOperationReservationIDs.remove(reservationID)
        guard let reservation = surfaceOperationReservations.removeValue(
            forKey: reservationID
        ) else {
            return false
        }
        switch reservation {
        case .queued:
            return false
        case let .granted(surfaceID):
            guard cancellationRequested else { return true }
            releaseSurfaceOperation(surfaceID: surfaceID)
            return false
        case let .cancelledAfterGrant(surfaceID):
            releaseSurfaceOperation(surfaceID: surfaceID)
            return false
        }
    }

    private func reserveSurfaceOperationReservationID() -> UInt64 {
        // Wrapping is deliberate but collision-free: every identifier becomes
        // visible in this live set before the actor can suspend at a test hook
        // or continuation. At most the finite in-memory waiter population is
        // probed, so UInt64 rollover cannot alias an outstanding reservation.
        while true {
            let candidate = nextSurfaceOperationReservationID
            nextSurfaceOperationReservationID &+= 1
            if reservedSurfaceOperationReservationIDs.insert(candidate).inserted {
                return candidate
            }
        }
    }

    private func releaseSurfaceOperation(surfaceID: UInt32) {
        while var waiters = surfaceOperationWaiters[surfaceID], !waiters.isEmpty {
            let reservationID = waiters.removeFirst()
            surfaceOperationWaiters[surfaceID] = waiters.isEmpty ? nil : waiters
            guard case let .queued(_, continuation) =
                surfaceOperationReservations[reservationID]
            else {
                continue
            }
            surfaceOperationReservations[reservationID] = .granted(surfaceID: surfaceID)
            continuation.resume(returning: .acquired)
            return
        }
        activeSurfaceOperations.remove(surfaceID)
    }

    private func surface(id: UInt32) throws(RenderError) -> Surface {
        guard let surface = surfaces[id] else {
            throw .unknownSurface(id)
        }
        return surface
    }

    private func applyCanonicalMutation(
        to surface: Surface,
        revision nextRevision: UInt64,
        mutationGeneration nextMutationGeneration: UInt64,
        mutation: CanonicalCPUMutation
    ) async throws(RenderError) -> CanonicalMutationAttempt {
        guard surface.storage.dataRevision != surface.revision,
              let unified = surface.storage.unifiedBacking,
              let sourceRevision = unified.current,
              sourceRevision.revision == surface.revision
        else {
            return .notEligible
        }
        guard let writable = unified.pool.checkoutWritable(
            namespace: unified.namespace,
            surfaceID: surface.id,
            width: surface.width,
            height: surface.height,
            source: sourceRevision,
            allowsInPlaceSource: true
        ) else {
            return .fallback
        }
        let copiesCanonicalSource = writable.requiresSourceSynchronization

        guard await writable.synchronizeFromSource() else {
            revisionedGPUErrors &+= 1
            return .fallback
        }
        guard var liveSurface = surfaces[surface.id],
              liveSurface.lifecycleGeneration == surface.lifecycleGeneration,
              liveSurface.revision == surface.revision,
              var liveUnified = liveSurface.storage.unifiedBacking,
              liveUnified.current === sourceRevision
        else {
            throw .backingMaterializationFailed
        }

        guard let kernelMetrics = writable.withLockedMutableBytes({ baseAddress, bytesPerRow in
            applyCanonicalMutation(
                mutation,
                baseAddress: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }) else {
            // An in-place candidate has not changed when the lock body never
            // ran. Restore its committed metadata instead of aborting the live
            // canonical slot and forcing every later publication to recover.
            if !copiesCanonicalSource {
                guard writable.finish(revision: sourceRevision.revision) != nil else {
                    preconditionFailure("unmodified IOSurface source could not be released")
                }
            }
            return .fallback
        }
        guard let committed = writable.finish(revision: nextRevision) else {
            preconditionFailure("validated IOSurface CPU mutation could not be committed")
        }

        liveSurface.revision = nextRevision
        liveSurface.mutationGeneration = nextMutationGeneration
        liveUnified.current = committed
        liveUnified.damageJournal.clear()
        liveUnified.damageHistory.reset(at: nextRevision)
        liveSurface.storage.unifiedBacking = liveUnified
        let region = mutation.region
        for rectangle in region {
            liveSurface.storage.recordPublicationDamage(rectangle)
        }
        currentFramePixelStorage[liveSurface.id] = nil
        surfaces[liveSurface.id] = liveSurface
        recordPixelKernelMetrics(kernelMetrics)
        Self.saturatingAdd(kernelMetrics.writtenBytes, to: &directIOSurfaceWriteBytes)
        if copiesCanonicalSource {
            Self.saturatingAdd(
                UInt64(liveSurface.width * liveSurface.height * 4),
                to: &gpuCopyBytes
            )
        }
        for rectangle in region {
            recordDamage(rectangle)
        }
        return .committed(surfaceRevision(of: liveSurface))
    }

    private func applyCanonicalCrossSurfaceCopy(
        destinationSurface: Surface,
        sourceSurface: Surface,
        revision nextRevision: UInt64,
        mutationGeneration nextMutationGeneration: UInt64,
        region: PixelRegion,
        destination: PixelRect,
        source: PixelRect
    ) async throws(RenderError) -> CanonicalMutationAttempt {
        guard destinationSurface.storage.dataRevision != destinationSurface.revision,
              sourceSurface.storage.dataRevision != sourceSurface.revision,
              let destinationUnified = destinationSurface.storage.unifiedBacking,
              let sourceUnified = sourceSurface.storage.unifiedBacking,
              let destinationRevision = destinationUnified.current,
              let sourceRevision = sourceUnified.current,
              destinationRevision.revision == destinationSurface.revision,
              sourceRevision.revision == sourceSurface.revision
        else {
            return .notEligible
        }
        guard let writable = destinationUnified.pool.checkoutWritable(
            namespace: destinationUnified.namespace,
            surfaceID: destinationSurface.id,
            width: destinationSurface.width,
            height: destinationSurface.height,
            source: destinationRevision,
            allowsInPlaceSource: true
        ) else {
            return .fallback
        }
        let copiesCanonicalDestination = writable.requiresSourceSynchronization
        guard await writable.synchronizeFromSource() else {
            revisionedGPUErrors &+= 1
            return .fallback
        }
        guard var liveDestination = surfaces[destinationSurface.id],
              liveDestination.lifecycleGeneration == destinationSurface.lifecycleGeneration,
              liveDestination.revision == destinationSurface.revision,
              var liveDestinationUnified = liveDestination.storage.unifiedBacking,
              liveDestinationUnified.current === destinationRevision,
              let liveSource = surfaces[sourceSurface.id],
              liveSource.lifecycleGeneration == sourceSurface.lifecycleGeneration,
              liveSource.revision == sourceSurface.revision,
              liveSource.storage.unifiedBacking?.current === sourceRevision
        else {
            throw .backingMaterializationFailed
        }

        let lockedMetrics = sourceRevision.withLockedBytes { sourceBase, sourceBytesPerRow in
            writable.withLockedMutableBytes { destinationBase, destinationBytesPerRow in
                var metrics = PixelKernelMetrics()
                for rectangle in region {
                    let sourceRectangle = translatedSourceAfterValidation(
                        for: rectangle,
                        destination: destination,
                        source: source
                    )
                    Self.accumulate(
                        Self.copySurfacePixels(
                            sourceBase: sourceBase,
                            sourceBytesPerRow: sourceBytesPerRow,
                            destinationBase: destinationBase,
                            destinationBytesPerRow: destinationBytesPerRow,
                            destination: rectangle,
                            source: sourceRectangle
                        ),
                        into: &metrics
                    )
                }
                return metrics
            }
        }
        guard let destinationLockResult = lockedMetrics,
              let kernelMetrics = destinationLockResult
        else {
            if !copiesCanonicalDestination {
                guard writable.finish(revision: destinationRevision.revision) != nil else {
                    preconditionFailure("unmodified IOSurface destination could not be released")
                }
            }
            return .fallback
        }
        guard let committed = writable.finish(revision: nextRevision) else {
            preconditionFailure("validated cross-Surface IOSurface copy could not be committed")
        }

        liveDestination.revision = nextRevision
        liveDestination.mutationGeneration = nextMutationGeneration
        liveDestinationUnified.current = committed
        liveDestinationUnified.damageJournal.clear()
        liveDestinationUnified.damageHistory.reset(at: nextRevision)
        liveDestination.storage.unifiedBacking = liveDestinationUnified
        for rectangle in region {
            liveDestination.storage.recordPublicationDamage(rectangle)
        }
        currentFramePixelStorage[liveDestination.id] = nil
        surfaces[liveDestination.id] = liveDestination
        recordPixelKernelMetrics(kernelMetrics)
        Self.saturatingAdd(kernelMetrics.writtenBytes, to: &directIOSurfaceWriteBytes)
        if copiesCanonicalDestination {
            Self.saturatingAdd(
                UInt64(liveDestination.width * liveDestination.height * 4),
                to: &gpuCopyBytes
            )
        }
        for rectangle in region {
            recordDamage(rectangle)
        }
        return .committed(surfaceRevision(of: liveDestination))
    }

    private func applyCanonicalMutation(
        _ mutation: CanonicalCPUMutation,
        baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int
    ) -> PixelKernelMetrics {
        var metrics = PixelKernelMetrics()
        switch mutation {
        case let .fill(region, colorBGRA):
            for rectangle in region {
                Self.accumulate(
                    Self.fillPixels(
                        baseAddress: baseAddress,
                        bytesPerRow: bytesPerRow,
                        rectangle: rectangle,
                        colorBGRA: colorBGRA
                    ),
                    into: &metrics
                )
            }
        case let .sameSurfaceCopy(region, destination, source):
            for rectangle in region.copyTraversal(source: source, destination: destination) {
                let sourceRectangle = translatedSourceAfterValidation(
                    for: rectangle,
                    destination: destination,
                    source: source
                )
                Self.accumulate(
                    Self.copySurfacePixels(
                        baseAddress: baseAddress,
                        bytesPerRow: bytesPerRow,
                        destination: rectangle,
                        source: sourceRectangle
                    ),
                    into: &metrics
                )
            }
        case let .bitmapCopy(region, destination, bitmap, source, preservesAlpha):
            for rectangle in region {
                let sourceRectangle = translatedSourceAfterValidation(
                    for: rectangle,
                    destination: destination,
                    source: source
                )
                copyRawBitmap(
                    bitmap,
                    source: sourceRectangle,
                    to: baseAddress.advanced(
                        by: rectangle.y * bytesPerRow + rectangle.x * 4
                    ),
                    destinationBytesPerRow: bytesPerRow,
                    preservesAlpha: preservesAlpha
                )
                metrics.writtenBytes += UInt64(
                    rectangle.width * rectangle.height * 4
                )
            }
        }
        return metrics
    }

    private static func accumulate(
        _ addition: PixelKernelMetrics,
        into metrics: inout PixelKernelMetrics
    ) {
        saturatingAdd(addition.bulkCopyCalls, to: &metrics.bulkCopyCalls)
        saturatingAdd(addition.rowCopyCalls, to: &metrics.rowCopyCalls)
        saturatingAdd(addition.fillKernelCalls, to: &metrics.fillKernelCalls)
        saturatingAdd(addition.writtenBytes, to: &metrics.writtenBytes)
    }

    /// Removes the dictionary's value-semantic reference before mutation. Every
    /// fallible GPU readback is staged first, so failure restores the exact
    /// original surface rather than a partially updated CPU cache.
    private func prepareForMutation(_ surface: inout Surface) throws(RenderError) {
        surfaces[surface.id] = nil
        do {
            let materializedPixels = try materializedPixelsIfNeeded(for: surface)
            commitMaterializedPixels(materializedPixels, to: &surface)
        } catch {
            surfaces[surface.id] = surface
            throw error
        }
    }

    /// Cross-surface copy stages both source and destination. No CPU cache is
    /// committed until all required GPU readbacks have succeeded.
    private func prepareForCrossSurfaceCopy(
        destination: inout Surface,
        source: inout Surface
    ) throws(RenderError) {
        surfaces[destination.id] = nil
        surfaces[source.id] = nil
        do {
            let destinationPixels = try materializedPixelsIfNeeded(for: destination)
            let sourcePixels = try materializedPixelsIfNeeded(for: source)

            commitMaterializedPixels(destinationPixels, to: &destination)
            commitMaterializedPixels(sourcePixels, to: &source)
            surfaces[source.id] = source
        } catch {
            surfaces[destination.id] = destination
            surfaces[source.id] = source
            throw error
        }
    }

    private func materializedPixelsIfNeeded(
        for surface: Surface
    ) throws(RenderError) -> Data? {
        guard surface.storage.dataRevision != surface.revision else {
            return nil
        }
        guard let current = surface.storage.unifiedBacking?.current,
              current.revision == surface.revision,
              let pixels = current.copyPixels(),
              pixels.count == surface.bytesPerRow * surface.height
        else {
            throw .backingMaterializationFailed
        }
        return pixels
    }

    private func commitMaterializedPixels(
        _ pixels: consuming Data?,
        to surface: inout Surface
    ) {
        guard let pixels else { return }
        surface.storage.pixels = pixels
        surface.storage.dataRevision = surface.revision
        materializationMetrics.record(bytes: pixels.count)
    }

    private func copyRawBitmap(
        _ bitmap: RawBitmap,
        source: PixelRect,
        to destinationBase: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        preservesAlpha: Bool
    ) {
        bitmap.pixels.withUnsafeBytes { sourceBytes in
            guard let sourceBase = sourceBytes.baseAddress else { return }
            for destinationRow in 0..<source.height {
                let logicalSourceRow = source.y + destinationRow
                let sourceRow = bitmap.topDown
                    ? logicalSourceRow
                    : bitmap.height - 1 - logicalSourceRow
                let sourceStart = sourceRow * bitmap.stride + source.x * 4
                let sourceRowBase = sourceBase.advanced(by: sourceStart)
                let destinationRowBase = destinationBase.advanced(
                    by: destinationRow * destinationBytesPerRow
                )
                if preservesAlpha {
                    memmove(destinationRowBase, sourceRowBase, source.width * 4)
                } else {
                    spice_copy_bgra_opaque(
                        sourceRowBase.assumingMemoryBound(to: UInt8.self),
                        destinationRowBase.assumingMemoryBound(to: UInt8.self),
                        source.width
                    )
                }
            }
        }
    }

    private func fillPixels(
        in surface: inout Surface,
        rectangle: PixelRect,
        colorBGRA: UInt32
    ) {
        let bytesPerRow = surface.bytesPerRow
        let metrics = surface.pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return PixelKernelMetrics() }
            return Self.fillPixels(
                baseAddress: baseAddress,
                bytesPerRow: bytesPerRow,
                rectangle: rectangle,
                colorBGRA: colorBGRA
            )
        }
        recordPixelKernelMetrics(metrics)
    }

    private func copySurfacePixels(
        in surface: inout Surface,
        destination: PixelRect,
        source: PixelRect
    ) {
        let bytesPerRow = surface.bytesPerRow
        let metrics = surface.pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return PixelKernelMetrics() }
            return Self.copySurfacePixels(
                baseAddress: baseAddress,
                bytesPerRow: bytesPerRow,
                destination: destination,
                source: source
            )
        }
        recordPixelKernelMetrics(metrics)
    }

    private func copySurfacePixels(
        from sourceSurface: Surface,
        to destinationSurface: inout Surface,
        destination: PixelRect,
        source: PixelRect
    ) {
        let sourceBytesPerRow = sourceSurface.bytesPerRow
        let destinationBytesPerRow = destinationSurface.bytesPerRow
        let metrics = sourceSurface.pixels.withUnsafeBytes { sourceBytes in
            destinationSurface.pixels.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress
                else {
                    return PixelKernelMetrics()
                }
                return Self.copySurfacePixels(
                    sourceBase: sourceBase,
                    sourceBytesPerRow: sourceBytesPerRow,
                    destinationBase: destinationBase,
                    destinationBytesPerRow: destinationBytesPerRow,
                    destination: destination,
                    source: source
                )
            }
        }
        recordPixelKernelMetrics(metrics)
    }

    private static func fillPixels(
        baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        rectangle: PixelRect,
        colorBGRA: UInt32
    ) -> PixelKernelMetrics {
        spice_fill_bgra32(
            baseAddress.advanced(by: rectangle.y * bytesPerRow + rectangle.x * 4)
                .assumingMemoryBound(to: UInt8.self),
            bytesPerRow,
            rectangle.width,
            rectangle.height,
            colorBGRA
        )
        return PixelKernelMetrics(
            fillKernelCalls: 1,
            writtenBytes: UInt64(rectangle.width * rectangle.height * 4)
        )
    }

    private static func copySurfacePixels(
        baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        destination: PixelRect,
        source: PixelRect
    ) -> PixelKernelMetrics {
        let rowBytes = destination.width * 4
        let overlaps = source.x < destination.x + destination.width
            && destination.x < source.x + source.width
            && source.y < destination.y + destination.height
            && destination.y < source.y + source.height
        let usesBulkCopy = !overlaps
            && (destination.height == 1 || rowBytes == bytesPerRow)
        if usesBulkCopy {
            _ = memmove(
                baseAddress.advanced(by: destination.y * bytesPerRow + destination.x * 4),
                baseAddress.advanced(by: source.y * bytesPerRow + source.x * 4),
                rowBytes * destination.height
            )
        } else if destination.y > source.y {
            for row in stride(from: destination.height - 1, through: 0, by: -1) {
                _ = memmove(
                    baseAddress.advanced(
                        by: (destination.y + row) * bytesPerRow + destination.x * 4
                    ),
                    baseAddress.advanced(
                        by: (source.y + row) * bytesPerRow + source.x * 4
                    ),
                    rowBytes
                )
            }
        } else {
            for row in 0..<destination.height {
                _ = memmove(
                    baseAddress.advanced(
                        by: (destination.y + row) * bytesPerRow + destination.x * 4
                    ),
                    baseAddress.advanced(
                        by: (source.y + row) * bytesPerRow + source.x * 4
                    ),
                    rowBytes
                )
            }
        }
        return PixelKernelMetrics(
            bulkCopyCalls: usesBulkCopy ? 1 : 0,
            rowCopyCalls: usesBulkCopy ? 0 : UInt64(destination.height),
            writtenBytes: UInt64(rowBytes * destination.height)
        )
    }

    private static func copySurfacePixels(
        sourceBase: UnsafeRawPointer,
        sourceBytesPerRow: Int,
        destinationBase: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        destination: PixelRect,
        source: PixelRect
    ) -> PixelKernelMetrics {
        let rowBytes = destination.width * 4
        let usesBulkCopy = destination.height == 1
            || (rowBytes == sourceBytesPerRow && rowBytes == destinationBytesPerRow)
        if usesBulkCopy {
            _ = memcpy(
                destinationBase.advanced(
                    by: destination.y * destinationBytesPerRow + destination.x * 4
                ),
                sourceBase.advanced(by: source.y * sourceBytesPerRow + source.x * 4),
                rowBytes * destination.height
            )
        } else {
            for row in 0..<destination.height {
                _ = memcpy(
                    destinationBase.advanced(
                        by: (destination.y + row) * destinationBytesPerRow
                            + destination.x * 4
                    ),
                    sourceBase.advanced(
                        by: (source.y + row) * sourceBytesPerRow + source.x * 4
                    ),
                    rowBytes
                )
            }
        }
        return PixelKernelMetrics(
            bulkCopyCalls: usesBulkCopy ? 1 : 0,
            rowCopyCalls: usesBulkCopy ? 0 : UInt64(destination.height),
            writtenBytes: UInt64(rowBytes * destination.height)
        )
    }

    private func recordPixelKernelMetrics(_ metrics: PixelKernelMetrics) {
        Self.saturatingAdd(metrics.bulkCopyCalls, to: &bulkCopyCalls)
        Self.saturatingAdd(metrics.rowCopyCalls, to: &rowCopyCalls)
        Self.saturatingAdd(metrics.fillKernelCalls, to: &fillKernelCalls)
    }

    private func translatedSource(
        for rectangle: PixelRect,
        destination: PixelRect,
        source: PixelRect
    ) throws(RenderError) -> PixelRect {
        guard destination.width == source.width,
              destination.height == source.height,
              destination.width > 0,
              destination.height > 0
        else {
            throw .invalidRectangle
        }
        let (offsetX, offsetXOverflow) = rectangle.x.subtractingReportingOverflow(
            destination.x
        )
        let (offsetY, offsetYOverflow) = rectangle.y.subtractingReportingOverflow(
            destination.y
        )
        let (offsetRight, offsetRightOverflow) = offsetX.addingReportingOverflow(
            rectangle.width
        )
        let (offsetBottom, offsetBottomOverflow) = offsetY.addingReportingOverflow(
            rectangle.height
        )
        guard !offsetXOverflow, !offsetYOverflow,
              !offsetRightOverflow, !offsetBottomOverflow,
              offsetX >= 0, offsetY >= 0,
              offsetRight <= destination.width,
              offsetBottom <= destination.height
        else {
            throw .invalidRectangle
        }
        let (translatedX, translatedXOverflow) = source.x.addingReportingOverflow(offsetX)
        let (translatedY, translatedYOverflow) = source.y.addingReportingOverflow(offsetY)
        guard !translatedXOverflow, !translatedYOverflow else {
            throw .integerOverflow
        }
        return PixelRect(
            x: translatedX,
            y: translatedY,
            width: rectangle.width,
            height: rectangle.height
        )
    }

    /// Used only after `translatedSource` has validated every region segment.
    private func translatedSourceAfterValidation(
        for rectangle: PixelRect,
        destination: PixelRect,
        source: PixelRect
    ) -> PixelRect {
        let offsetX = rectangle.x - destination.x
        let offsetY = rectangle.y - destination.y
        return PixelRect(
            x: source.x + offsetX,
            y: source.y + offsetY,
            width: rectangle.width,
            height: rectangle.height
        )
    }

    private func validate(_ bitmap: RawBitmap) throws(RenderError) {
        guard bitmap.width > 0, bitmap.height > 0 else {
            throw .invalidBitmap
        }
        let (minimumStride, strideOverflow) = bitmap.width.multipliedReportingOverflow(by: 4)
        guard !strideOverflow, bitmap.stride >= minimumStride else {
            throw .invalidBitmap
        }
        let (requiredBytes, sizeOverflow) = bitmap.stride.multipliedReportingOverflow(
            by: bitmap.height
        )
        guard !sizeOverflow, requiredBytes == bitmap.pixels.count else {
            throw .invalidBitmap
        }
    }

    private func validate(_ rectangle: PixelRect, in bitmap: RawBitmap) throws(RenderError) {
        guard rectangle.x >= 0, rectangle.y >= 0,
              rectangle.width > 0, rectangle.height > 0
        else {
            throw .invalidBitmap
        }
        let (right, rightOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
        let (bottom, bottomOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
        guard !rightOverflow, !bottomOverflow,
              right <= bitmap.width, bottom <= bitmap.height
        else {
            throw .invalidBitmap
        }
    }

    private func commitRegionMutation(
        _ surface: inout Surface,
        region: PixelRegion,
        revision: UInt64,
        mutationGeneration: UInt64
    ) -> SurfaceRevision {
        surface.revision = revision
        surface.mutationGeneration = mutationGeneration
        for rectangle in region {
            surface.storage.recordDamage(rectangle, revision: revision)
        }
        currentFramePixelStorage[surface.id] = nil
        surfaces[surface.id] = surface
        for rectangle in region {
            recordDamage(rectangle)
        }
        recordMutationTransaction()
        return surfaceRevision(of: surface)
    }

    private func recordMutationTransaction() {
        Self.saturatingAdd(1, to: &mutationTransactions)
    }

    private static func saturatingAdd(_ amount: UInt64, to value: inout UInt64) {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        if overflow {
            value = UInt64.max
        } else {
            value = sum
        }
    }

    private func validate(_ rectangle: PixelRect, in surface: Surface) throws(RenderError) {
        guard rectangle.x >= 0, rectangle.y >= 0,
              rectangle.width > 0, rectangle.height > 0
        else {
            throw .invalidRectangle
        }
        let (right, rightOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
        let (bottom, bottomOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
        guard !rightOverflow, !bottomOverflow,
              right <= surface.width, bottom <= surface.height
        else {
            throw .invalidRectangle
        }
    }

    private func checkedByteCount(width: Int, height: Int) throws(RenderError) -> Int {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else {
            throw .integerOverflow
        }
        guard bytes <= limits.maximumSurfaceBytes else {
            throw .surfaceTooLarge(bytes: bytes, maximum: limits.maximumSurfaceBytes)
        }
        return bytes
    }

    private func advanceLifecycleGeneration(for surfaceID: UInt32) throws(RenderError) -> UInt64 {
        let advanced = try nextLifecycleGeneration(for: surfaceID)
        lifecycleGenerations[surfaceID] = advanced
        return advanced
    }

    private func nextLifecycleGeneration(for surfaceID: UInt32) throws(RenderError) -> UInt64 {
        let current = lifecycleGenerations[surfaceID] ?? 0
        let (advanced, overflow) = current.addingReportingOverflow(1)
        guard !overflow else {
            throw .integerOverflow
        }
        return advanced
    }

    private func advancedRevision(_ revision: UInt64) throws(RenderError) -> UInt64 {
        let (advanced, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else {
            throw .integerOverflow
        }
        return advanced
    }

    private func recordDamage(_ rectangle: PixelRect) {
        let bytes = UInt64(rectangle.width) * UInt64(rectangle.height) * 4
        damageOperations &+= 1
        damageBytes &+= bytes
    }
}
