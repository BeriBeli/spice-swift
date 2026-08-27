import CoreVideo
import Foundation
import IOSurface
@preconcurrency import Metal
import Synchronization

/// Process-wide Metal device resolution. Besides avoiding redundant capability
/// probes, this keeps SkyLight/TCC-backed default-device discovery out of
/// concurrent actor and test initialization paths.
package final class SpiceMetalSystemDevice: @unchecked Sendable {
    package static let shared = SpiceMetalSystemDevice()

    package let device: (any MTLDevice)?

    private init() {
        device = MTLCreateSystemDefaultDevice()
    }
}

package struct RevisionedIOSurfacePoolLimits: Sendable, Equatable {
    package var maximumFramesPerSurface: Int
    package var maximumBytes: Int

    package init(
        maximumFramesPerSurface: Int = 3,
        maximumBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumFramesPerSurface = max(0, maximumFramesPerSurface)
        self.maximumBytes = max(0, maximumBytes)
    }
}

package struct RevisionedIOSurfacePoolMetrics: Sendable, Equatable {
    package let enabled: Bool
    package let allocatedFrames: Int
    package let allocatedBytes: Int
    package let inFlightLeases: Int
    package let poolExhaustions: UInt64
    package let gpuCopies: UInt64
    package let gpuCopyBytes: UInt64
    package let gpuErrors: UInt64
    package let recommendedMaximumWorkingSetSize: UInt64
    package let currentMetalAllocatedSize: UInt64
}

/// A stable namespace prevents equal SPICE surface IDs on different Display
/// channels from sharing a revision ring. Slots retain the token for their
/// entire physical lifetime, so an object-identity value cannot be recycled
/// while an old lease is still alive.
package final class RevisionedIOSurfaceNamespace: @unchecked Sendable {
    package init() {}
}

/// Process-wide accounting shared by the revisioned and Data-fallback
/// IOSurface pools. The application-owned 256 MiB limit remains authoritative;
/// Metal's working-set properties are diagnostics only.
package final class IOSurfaceAllocationBudget: Sendable {
    package static let shared = IOSurfaceAllocationBudget()

    private struct State {
        var allocatedBytes = 0
    }

    package let maximumBytes: Int
    private let state = Mutex(State())

    package init(maximumBytes: Int = 256 * 1_024 * 1_024) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func reserve(_ bytes: Int) -> Bool {
        guard bytes >= 0 else { return false }
        return state.withLock { state in
            let (total, overflow) = state.allocatedBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= maximumBytes else { return false }
            state.allocatedBytes = total
            return true
        }
    }

    func release(_ bytes: Int) {
        guard bytes > 0 else { return }
        state.withLock { state in
            precondition(state.allocatedBytes >= bytes)
            state.allocatedBytes -= bytes
        }
    }

    package var allocatedBytes: Int {
        state.withLock(\.allocatedBytes)
    }
}

private struct RevisionedFrameKey: Hashable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
}

/// One allocation in the revision ring. Mutable access is granted only while
/// `writer` is true in the owning pool. Published frames increment `leaseCount`
/// and therefore cannot be selected for another write until every consumer has
/// released its lease.
private final class RevisionedSurfaceSlot: @unchecked Sendable {
    let namespace: RevisionedIOSurfaceNamespace
    let surfaceID: UInt32
    let key: RevisionedFrameKey
    let surface: IOSurfaceRef
    let bytesPerRow: Int
    let allocationSize: Int
    private let allocationBudget: IOSurfaceAllocationBudget

    init(
        namespace: RevisionedIOSurfaceNamespace,
        surfaceID: UInt32,
        key: RevisionedFrameKey,
        surface: IOSurfaceRef,
        allocationBudget: IOSurfaceAllocationBudget
    ) {
        self.namespace = namespace
        self.surfaceID = surfaceID
        self.key = key
        self.surface = surface
        bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        allocationSize = IOSurfaceGetAllocSize(surface)
        self.allocationBudget = allocationBudget
    }

    deinit {
        allocationBudget.release(allocationSize)
    }
}

private final class IOSurfaceBlitter: @unchecked Sendable {
    let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue

    init?(device: any MTLDevice) {
        guard let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
    }

    func validatesMapping() -> Bool {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: 1,
            kIOSurfaceHeight: 1,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            return false
        }
        return makeTexture(surface: surface, width: 1, height: 1) != nil
    }

    func copy(
        source: RevisionedSurfaceSlot,
        destination: RevisionedSurfaceSlot
    ) async -> Bool {
        guard source.key == destination.key,
              let sourceTexture = makeTexture(
                  surface: source.surface,
                  width: source.key.width,
                  height: source.key.height
              ),
              let destinationTexture = makeTexture(
                  surface: destination.surface,
                  width: destination.key.width,
                  height: destination.key.height
              ),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else {
            return false
        }

        encoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: source.key.width,
                height: source.key.height,
                depth: 1
            ),
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()

        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { completedBuffer in
                withExtendedLifetime((sourceTexture, destinationTexture)) {
                    continuation.resume(returning: completedBuffer.status == .completed)
                }
            }
            commandBuffer.commit()
        }
    }

    private func makeTexture(
        surface: IOSurfaceRef,
        width: Int,
        height: Int
    ) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }
}

/// Shared allocation budget for per-surface revision rings.
///
/// The pool is enabled only on Apple Silicon devices that report unified memory,
/// support Apple GPU family 7 or newer, and successfully map a probe IOSurface as
/// a Metal texture. Callers must retain the Data backend when this initializer
/// returns `nil`.
package final class RevisionedIOSurfacePool: @unchecked Sendable {
    private struct SlotState {
        let slot: RevisionedSurfaceSlot
        var writer = false
        var leaseCount = 0
        var retired = false
        var canonical = false
        var revision: UInt64?
    }

    private struct SurfaceKey: Hashable, Sendable {
        let namespaceID: ObjectIdentifier
        let surfaceID: UInt32
    }

    private struct State {
        var slots: [ObjectIdentifier: SlotState] = [:]
        var poolExhaustions: UInt64 = 0
        var gpuCopies: UInt64 = 0
        var gpuCopyBytes: UInt64 = 0
        var gpuErrors: UInt64 = 0
        var operationTails: [SurfaceKey: Task<Void, Never>] = [:]
        var operationSerials: [SurfaceKey: UInt64] = [:]
    }

    private let limits: RevisionedIOSurfacePoolLimits
    private let blitter: IOSurfaceBlitter
    private let allocationBudget: IOSurfaceAllocationBudget
    private let state = Mutex(State())

    /// Production stores share one pool and one allocation budget. This makes
    /// the 256 MiB limit process-wide instead of multiplying it by Display
    /// channel count.
    package static let sharedIfSupported: RevisionedIOSurfacePool? = {
        makeIfSupported(allocationBudget: .shared)
    }()

    package static func makeIfSupported(
        limits: RevisionedIOSurfacePoolLimits = .init()
    ) -> RevisionedIOSurfacePool? {
        makeIfSupported(
            limits: limits,
            allocationBudget: IOSurfaceAllocationBudget(maximumBytes: limits.maximumBytes)
        )
    }

    private static func makeIfSupported(
        limits: RevisionedIOSurfacePoolLimits = .init(),
        allocationBudget: IOSurfaceAllocationBudget
    ) -> RevisionedIOSurfacePool? {
        #if arch(arm64)
        guard limits.maximumFramesPerSurface > 0,
              limits.maximumBytes > 0,
              let device = SpiceMetalSystemDevice.shared.device,
              device.hasUnifiedMemory,
              device.supportsFamily(.apple7),
              let blitter = IOSurfaceBlitter(device: device),
              blitter.validatesMapping()
        else {
            return nil
        }
        return RevisionedIOSurfacePool(
            limits: limits,
            blitter: blitter,
            allocationBudget: allocationBudget
        )
        #else
        _ = limits
        return nil
        #endif
    }

    /// Test/internal initializer. Production selection must use
    /// `makeIfSupported`, which performs the complete runtime capability gate.
    package init?(
        device: any MTLDevice,
        limits: RevisionedIOSurfacePoolLimits = .init()
    ) {
        guard limits.maximumFramesPerSurface > 0,
              limits.maximumBytes > 0,
              let blitter = IOSurfaceBlitter(device: device),
              blitter.validatesMapping()
        else {
            return nil
        }
        self.limits = limits
        self.blitter = blitter
        allocationBudget = IOSurfaceAllocationBudget(maximumBytes: limits.maximumBytes)
    }

    private init(
        limits: RevisionedIOSurfacePoolLimits,
        blitter: IOSurfaceBlitter,
        allocationBudget: IOSurfaceAllocationBudget
    ) {
        self.limits = limits
        self.blitter = blitter
        self.allocationBudget = allocationBudget
    }

    package func checkoutWritable(
        namespace: RevisionedIOSurfaceNamespace,
        surfaceID: UInt32,
        width: Int,
        height: Int,
        source: RevisionedIOSurfaceRevision?,
        allowsInPlaceSource: Bool = false
    ) -> RevisionedIOSurfaceWritableFrame? {
        guard width > 0, height > 0 else {
            return nil
        }
        let (minimumRowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (minimumBytes, sizeOverflow) = minimumRowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sizeOverflow, minimumBytes <= limits.maximumBytes else {
            return nil
        }
        let key = RevisionedFrameKey(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        if allowsInPlaceSource, let source {
            let checkedOut = state.withLock { state -> Bool in
                let identifier = ObjectIdentifier(source.slot)
                guard var slotState = state.slots[identifier],
                      slotState.slot.namespace === namespace,
                      slotState.slot.surfaceID == surfaceID,
                      slotState.slot.key == key,
                      slotState.canonical,
                      !slotState.retired,
                      !slotState.writer,
                      slotState.leaseCount == 0,
                      slotState.revision == Optional(source.revision)
                else {
                    return false
                }
                slotState.writer = true
                state.slots[identifier] = slotState
                return true
            }
            if checkedOut {
                return RevisionedIOSurfaceWritableFrame(
                    slot: source.slot,
                    source: source,
                    destinationRevision: source.revision,
                    pool: self
                )
            }
        }

        let existing = state.withLock {
            state -> (slot: RevisionedSurfaceSlot, revision: UInt64?)? in
            let sourceIdentifier = source.map { ObjectIdentifier($0.slot) }
            // Fallible GPU callers do not opt into the validated CPU-only
            // in-place path above. Their committed source remains excluded so
            // command failure cannot corrupt the published revision.
            var selected: (identifier: ObjectIdentifier, state: SlotState)?
            for (identifier, slotState) in state.slots {
                guard slotState.slot.namespace === namespace,
                      slotState.slot.surfaceID == surfaceID,
                      slotState.slot.key == key,
                      ObjectIdentifier(slotState.slot) != sourceIdentifier,
                      !slotState.retired,
                      !slotState.writer,
                      slotState.leaseCount == 0
                else {
                    continue
                }
                let shouldSelect: Bool
                if let selected {
                    switch (selected.state.revision, slotState.revision) {
                    case (nil, .some):
                        shouldSelect = true
                    case let (.some(selectedRevision), .some(candidateRevision)):
                        shouldSelect = candidateRevision > selectedRevision
                    default:
                        shouldSelect = false
                    }
                } else {
                    shouldSelect = true
                }
                if shouldSelect {
                    selected = (identifier, slotState)
                }
            }
            if let selected {
                var slotState = selected.state
                slotState.writer = true
                state.slots[selected.identifier] = slotState
                return (slotState.slot, slotState.revision)
            }
            return nil
        }
        if let existing {
            return RevisionedIOSurfaceWritableFrame(
                slot: existing.slot,
                source: source,
                destinationRevision: existing.revision,
                pool: self
            )
        }

        let surfaceSlotCount = state.withLock { state in
            state.slots.values.reduce(into: 0) { count, slotState in
                if slotState.slot.surfaceID == surfaceID {
                    guard slotState.slot.namespace === namespace else { return }
                    count += 1
                }
            }
        }
        guard surfaceSlotCount < limits.maximumFramesPerSurface else {
            recordPoolExhaustion()
            return nil
        }

        guard reserveWithPressureRecovery(minimumBytes) else {
            recordPoolExhaustion()
            return nil
        }
        var reservedBytes = minimumBytes
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            allocationBudget.release(reservedBytes)
            recordPoolExhaustion()
            return nil
        }
        let allocationSize = IOSurfaceGetAllocSize(surface)
        if allocationSize > reservedBytes {
            guard reserveWithPressureRecovery(allocationSize - reservedBytes) else {
                allocationBudget.release(reservedBytes)
                recordPoolExhaustion()
                return nil
            }
            reservedBytes = allocationSize
        } else if allocationSize < reservedBytes {
            allocationBudget.release(reservedBytes - allocationSize)
            reservedBytes = allocationSize
        }
        let slot = RevisionedSurfaceSlot(
            namespace: namespace,
            surfaceID: surfaceID,
            key: key,
            surface: surface,
            allocationBudget: allocationBudget
        )
        let (coveredBytes, coveredOverflow) = slot.bytesPerRow.multipliedReportingOverflow(by: height)
        guard slot.bytesPerRow >= minimumRowBytes,
              !coveredOverflow,
              coveredBytes <= slot.allocationSize
        else {
            // `slot` releases the completed reservation on deinit.
            recordPoolExhaustion()
            return nil
        }

        let inserted = state.withLock { state -> Bool in
            let allocatedBytes = state.slots.values.reduce(0) { $0 + $1.slot.allocationSize }
            let activeForSurface = state.slots.values.reduce(into: 0) { count, slotState in
                if slotState.slot.namespace === namespace,
                   slotState.slot.surfaceID == surfaceID {
                    count += 1
                }
            }
            guard activeForSurface < limits.maximumFramesPerSurface,
                  fitsWithinByteLimit(current: allocatedBytes, adding: slot.allocationSize)
            else {
                state.poolExhaustions &+= 1
                return false
            }
            state.slots[ObjectIdentifier(slot)] = SlotState(slot: slot, writer: true)
            return true
        }
        guard inserted else {
            return nil
        }
        return RevisionedIOSurfaceWritableFrame(
            slot: slot,
            source: source,
            destinationRevision: nil,
            pool: self
        )
    }

    package func retire(
        namespace: RevisionedIOSurfaceNamespace,
        surfaceID: UInt32
    ) {
        state.withLock { state in
            for identifier in Array(state.slots.keys) {
                guard var slotState = state.slots[identifier],
                      slotState.slot.namespace === namespace,
                      slotState.slot.surfaceID == surfaceID
                else {
                    continue
                }
                slotState.retired = true
                if !slotState.writer, slotState.leaseCount == 0 {
                    state.slots.removeValue(forKey: identifier)
                } else {
                    state.slots[identifier] = slotState
                }
            }
        }
    }

    package func metrics() -> RevisionedIOSurfacePoolMetrics {
        state.withLock { state in
            RevisionedIOSurfacePoolMetrics(
                enabled: true,
                allocatedFrames: state.slots.count,
                allocatedBytes: state.slots.values.reduce(0) { $0 + $1.slot.allocationSize },
                inFlightLeases: state.slots.values.reduce(0) { $0 + $1.leaseCount },
                poolExhaustions: state.poolExhaustions,
                gpuCopies: state.gpuCopies,
                gpuCopyBytes: state.gpuCopyBytes,
                gpuErrors: state.gpuErrors,
                recommendedMaximumWorkingSetSize: UInt64(blitter.device.recommendedMaxWorkingSetSize),
                currentMetalAllocatedSize: UInt64(blitter.device.currentAllocatedSize)
            )
        }
    }

    fileprivate func synchronize(
        _ destination: RevisionedSurfaceSlot,
        from source: RevisionedIOSurfaceRevision?
    ) async -> Bool {
        guard let source else {
            return clear(destination)
        }
        guard source.slot !== destination else {
            return true
        }
        guard source.slot.key == destination.key else {
            return false
        }

        let operation = enqueue(
            namespace: destination.namespace,
            surfaceID: destination.surfaceID
        ) { [blitter] in
            await blitter.copy(source: source.slot, destination: destination)
        }
        let succeeded = await operation.value
        state.withLock { state in
            if succeeded {
                state.gpuCopies &+= 1
                state.gpuCopyBytes &+= UInt64(destination.key.width * destination.key.height * 4)
            } else {
                state.gpuErrors &+= 1
            }
        }
        return succeeded
    }

    fileprivate func finish(
        _ slot: RevisionedSurfaceSlot,
        revision: UInt64
    ) -> RevisionedIOSurfaceRevision? {
        state.withLock { state in
            let identifier = ObjectIdentifier(slot)
            guard var slotState = state.slots[identifier], slotState.writer else {
                return nil
            }
            slotState.writer = false
            slotState.revision = revision
            slotState.canonical = true
            for otherIdentifier in Array(state.slots.keys) where otherIdentifier != identifier {
                guard var otherState = state.slots[otherIdentifier],
                      otherState.slot.namespace === slot.namespace,
                      otherState.slot.surfaceID == slot.surfaceID
                else { continue }
                otherState.canonical = false
                state.slots[otherIdentifier] = otherState
            }
            if slotState.retired, slotState.leaseCount == 0 {
                state.slots.removeValue(forKey: identifier)
                return nil
            }
            state.slots[identifier] = slotState
            return RevisionedIOSurfaceRevision(
                slot: slot,
                revision: revision,
                pool: self
            )
        }
    }

    fileprivate func abort(_ slot: RevisionedSurfaceSlot) {
        state.withLock { state in
            let identifier = ObjectIdentifier(slot)
            guard var slotState = state.slots[identifier], slotState.writer else {
                return
            }
            slotState.writer = false
            // A failed CPU/GPU operation may already have partially modified
            // the candidate. Never let a later incremental catch-up trust its
            // previous committed revision.
            slotState.revision = nil
            if slotState.retired, slotState.leaseCount == 0 {
                state.slots.removeValue(forKey: identifier)
            } else {
                state.slots[identifier] = slotState
            }
        }
    }

    fileprivate func makeLease(
        for revision: RevisionedIOSurfaceRevision
    ) -> IOSurfaceFrame? {
        let leased = state.withLock { state -> Bool in
            let identifier = ObjectIdentifier(revision.slot)
            guard var slotState = state.slots[identifier],
                  !slotState.retired,
                  !slotState.writer,
                  slotState.revision == Optional(revision.revision)
            else {
                return false
            }
            slotState.leaseCount += 1
            state.slots[identifier] = slotState
            return true
        }
        guard leased else {
            return nil
        }
        return IOSurfaceFrame(
            surface: revision.slot.surface,
            width: revision.slot.key.width,
            height: revision.slot.key.height,
            bytesPerRow: revision.slot.bytesPerRow,
            pixelFormat: revision.slot.key.pixelFormat,
            release: { [weak self, slot = revision.slot] in
                self?.releaseLease(slot)
            }
        )
    }

    private func releaseLease(_ slot: RevisionedSurfaceSlot) {
        state.withLock { state in
            let identifier = ObjectIdentifier(slot)
            guard var slotState = state.slots[identifier], slotState.leaseCount > 0 else {
                return
            }
            slotState.leaseCount -= 1
            if slotState.retired, !slotState.writer, slotState.leaseCount == 0 {
                state.slots.removeValue(forKey: identifier)
            } else {
                state.slots[identifier] = slotState
            }
        }
    }

    private func clear(_ slot: RevisionedSurfaceSlot) -> Bool {
        var seed: UInt32 = 0
        guard IOSurfaceLock(slot.surface, [], &seed) == 0 else {
            return false
        }
        defer { IOSurfaceUnlock(slot.surface, [], &seed) }
        IOSurfaceGetBaseAddress(slot.surface).initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: slot.bytesPerRow * slot.key.height
        )
        return true
    }

    private func enqueue(
        namespace: RevisionedIOSurfaceNamespace,
        surfaceID: UInt32,
        operation: @escaping @Sendable () async -> Bool
    ) -> Task<Bool, Never> {
        let surfaceKey = SurfaceKey(
            namespaceID: ObjectIdentifier(namespace),
            surfaceID: surfaceID
        )
        let scheduled: (task: Task<Bool, Never>, serial: UInt64) = state.withLock { state in
            let previous = state.operationTails[surfaceKey]
            let serial = (state.operationSerials[surfaceKey] ?? 0) &+ 1
            state.operationSerials[surfaceKey] = serial
            let task = Task {
                await previous?.value
                return await operation()
            }
            state.operationTails[surfaceKey] = Task {
                _ = await task.value
            }
            return (task, serial)
        }
        Task { [weak self] in
            _ = await scheduled.task.value
            self?.state.withLock { state in
                guard state.operationSerials[surfaceKey] == scheduled.serial else {
                    return
                }
                state.operationTails[surfaceKey] = nil
            }
        }
        return scheduled.task
    }

    private func fitsWithinByteLimit(current: Int, adding: Int) -> Bool {
        let (total, overflow) = current.addingReportingOverflow(adding)
        return !overflow && total <= limits.maximumBytes
    }

    private func recordPoolExhaustion() {
        state.withLock { state in
            state.poolExhaustions &+= 1
        }
    }

    private func reserveWithPressureRecovery(_ requestedBytes: Int) -> Bool {
        evictIdleCandidates(toFitAtLeast: requestedBytes)
        if allocationBudget.reserve(requestedBytes) {
            return true
        }
        guard allocationBudget === IOSurfaceAllocationBudget.shared else {
            return false
        }

        // Available legacy frames are only a cache. Prefer dropping them over
        // forcing the canonical Apple Silicon path back to a Data snapshot.
        IOSurfaceFramePool.shared.purgeAvailable()
        evictIdleCandidates(toFitAtLeast: requestedBytes)
        return allocationBudget.reserve(requestedBytes)
    }

    /// Discard only idle, non-canonical candidates. Current revisions and
    /// published leases remain immutable and non-evictable.
    private func evictIdleCandidates(toFitAtLeast requestedBytes: Int) {
        state.withLock { state in
            while true {
                let allocatedBytes = allocationBudget.allocatedBytes
                let availableBytes = allocatedBytes <= allocationBudget.maximumBytes
                    ? allocationBudget.maximumBytes - allocatedBytes
                    : 0
                guard requestedBytes > availableBytes else {
                    return
                }
                guard let identifier = state.slots.first(where: { _, slotState in
                    !slotState.canonical
                        && !slotState.writer
                        && slotState.leaseCount == 0
                })?.key else {
                    return
                }
                state.slots.removeValue(forKey: identifier)
            }
        }
    }
}

package final class RevisionedIOSurfaceWritableFrame: @unchecked Sendable {
    fileprivate let slot: RevisionedSurfaceSlot
    private let source: RevisionedIOSurfaceRevision?
    private let pool: RevisionedIOSurfacePool
    private let completed = Mutex(false)

    package let destinationRevision: UInt64?
    package var width: Int { slot.key.width }
    package var height: Int { slot.key.height }
    package var bytesPerRow: Int { slot.bytesPerRow }
    package var requiresSourceSynchronization: Bool {
        source.map { $0.slot !== slot } ?? false
    }

    fileprivate init(
        slot: RevisionedSurfaceSlot,
        source: RevisionedIOSurfaceRevision?,
        destinationRevision: UInt64?,
        pool: RevisionedIOSurfacePool
    ) {
        self.slot = slot
        self.source = source
        self.destinationRevision = destinationRevision
        self.pool = pool
    }

    deinit {
        let shouldAbort = completed.withLock { completed in
            if completed {
                return false
            }
            completed = true
            return true
        }
        if shouldAbort {
            pool.abort(slot)
        }
    }

    package func synchronizeFromSource() async -> Bool {
        await pool.synchronize(slot, from: source)
    }

    package func copyPackedPixels(
        _ pixels: Data,
        sourceBytesPerRow: Int,
        rectangles: [IOSurfaceCopyRectangle]
    ) -> UInt64? {
        let rowBytes = width * 4
        let expectedBytes = sourceBytesPerRow * height
        guard sourceBytesPerRow >= rowBytes, pixels.count == expectedBytes else {
            return nil
        }
        var seed: UInt32 = 0
        guard IOSurfaceLock(slot.surface, [], &seed) == 0 else {
            return nil
        }
        defer { IOSurfaceUnlock(slot.surface, [], &seed) }
        let destination = IOSurfaceGetBaseAddress(slot.surface)
        var copiedBytes: UInt64 = 0
        let copyRectangles = rectangles.isEmpty
            ? [IOSurfaceCopyRectangle(x: 0, y: 0, width: width, height: height)]
            : rectangles
        guard copyRectangles.allSatisfy({ $0.isValid(width: width, height: height) }) else {
            return nil
        }
        let succeeded = pixels.withUnsafeBytes { source -> Bool in
            guard let sourceBase = source.baseAddress else {
                return pixels.isEmpty
            }
            for rectangle in copyRectangles {
                let copyBytes = rectangle.width * 4
                for row in rectangle.y..<(rectangle.y + rectangle.height) {
                    destination.advanced(by: row * slot.bytesPerRow + rectangle.x * 4)
                        .copyMemory(
                            from: sourceBase.advanced(by: row * sourceBytesPerRow + rectangle.x * 4),
                            byteCount: copyBytes
                        )
                }
                copiedBytes &+= UInt64(copyBytes * rectangle.height)
            }
            return true
        }
        return succeeded ? copiedBytes : nil
    }

    /// Performs a synchronous CPU write while the IOSurface is locked. The
    /// writable candidate is not published until `finish(revision:)` succeeds.
    package func withLockedMutableBytes<Result>(
        _ body: (UnsafeMutableRawPointer, Int) -> Result
    ) -> Result? {
        var seed: UInt32 = 0
        guard IOSurfaceLock(slot.surface, [], &seed) == 0 else {
            return nil
        }
        defer { IOSurfaceUnlock(slot.surface, [], &seed) }
        return body(IOSurfaceGetBaseAddress(slot.surface), slot.bytesPerRow)
    }

    package func withIOSurface<Result, Failure: Error>(
        _ body: (IOSurfaceRef) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(slot.surface)
    }

    package func finish(revision: UInt64) -> RevisionedIOSurfaceRevision? {
        let shouldFinish = completed.withLock { completed in
            if completed {
                return false
            }
            completed = true
            return true
        }
        guard shouldFinish else {
            return nil
        }
        return pool.finish(slot, revision: revision)
    }
}

package final class RevisionedIOSurfaceRevision: @unchecked Sendable {
    fileprivate let slot: RevisionedSurfaceSlot
    private let pool: RevisionedIOSurfacePool

    package let revision: UInt64
    package var width: Int { slot.key.width }
    package var height: Int { slot.key.height }
    package var bytesPerRow: Int { slot.bytesPerRow }

    fileprivate init(
        slot: RevisionedSurfaceSlot,
        revision: UInt64,
        pool: RevisionedIOSurfacePool
    ) {
        self.slot = slot
        self.revision = revision
        self.pool = pool
    }

    package func makeLease() -> IOSurfaceFrame? {
        pool.makeLease(for: self)
    }

    /// Performs a synchronous read while the immutable revision is locked.
    /// The borrowed pointer never escapes the closure.
    package func withLockedBytes<Result>(
        _ body: (UnsafeRawPointer, Int) -> Result
    ) -> Result? {
        var seed: UInt32 = 0
        guard IOSurfaceLock(slot.surface, .readOnly, &seed) == 0 else {
            return nil
        }
        defer { IOSurfaceUnlock(slot.surface, .readOnly, &seed) }
        return body(IOSurfaceGetBaseAddress(slot.surface), slot.bytesPerRow)
    }

    package func copyPixels() -> Data? {
        var seed: UInt32 = 0
        guard IOSurfaceLock(slot.surface, .readOnly, &seed) == 0 else {
            return nil
        }
        defer { IOSurfaceUnlock(slot.surface, .readOnly, &seed) }
        let source = IOSurfaceGetBaseAddress(slot.surface)
        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else {
                return
            }
            for row in 0..<height {
                destinationBase.advanced(by: row * rowBytes).copyMemory(
                    from: source.advanced(by: row * slot.bytesPerRow),
                    byteCount: rowBytes
                )
            }
        }
        return pixels
    }
}

package struct IOSurfaceCopyRectangle: Sendable, Equatable {
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

    fileprivate func isValid(width surfaceWidth: Int, height surfaceHeight: Int) -> Bool {
        guard x >= 0, y >= 0, width > 0, height > 0 else {
            return false
        }
        let (right, rightOverflow) = x.addingReportingOverflow(width)
        let (bottom, bottomOverflow) = y.addingReportingOverflow(height)
        return !rightOverflow && !bottomOverflow
            && right <= surfaceWidth && bottom <= surfaceHeight
    }
}
