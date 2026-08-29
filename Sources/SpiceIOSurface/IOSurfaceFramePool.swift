import CoreVideo
import Darwin
import Foundation
import IOSurface
import Synchronization

package struct IOSurfaceFramePoolLimits: Sendable, Equatable {
    package var maximumFrames: Int
    package var maximumBytes: Int

    package init(
        maximumFrames: Int = 3,
        maximumBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumFrames = max(0, maximumFrames)
        self.maximumBytes = max(0, maximumBytes)
    }
}

package struct IOSurfaceFramePoolMetrics: Sendable, Equatable {
    package let allocatedFrames: Int
    package let availableFrames: Int
    package let inUseFrames: Int
    package let allocatedBytes: Int
}

private struct FrameKey: Hashable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
}

/// The only unchecked boundary around the non-Sendable Core Foundation handle.
/// Access to the IOSurface bytes is serialized by IOSurfaceLock/Unlock, while a
/// frame lease is immutable after publication.
private final class SurfaceEntry: @unchecked Sendable {
    let key: FrameKey
    let surface: IOSurfaceRef
    let bytesPerRow: Int
    let allocationSize: Int
    private let allocationBudget: IOSurfaceAllocationBudget

    init(
        key: FrameKey,
        surface: IOSurfaceRef,
        allocationBudget: IOSurfaceAllocationBudget
    ) {
        self.key = key
        self.surface = surface
        self.bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        self.allocationSize = IOSurfaceGetAllocSize(surface)
        self.allocationBudget = allocationBudget
    }

    deinit {
        allocationBudget.release(allocationSize)
    }
}

package final class IOSurfaceFrame: @unchecked Sendable {
    private let surface: IOSurfaceRef
    private let frameWidth: Int
    private let frameHeight: Int
    private let frameBytesPerRow: Int
    private let framePixelFormat: OSType
    private let release: @Sendable () -> Void

    package var id: UInt32 { IOSurfaceGetID(surface) }
    package var width: Int { frameWidth }
    package var height: Int { frameHeight }
    package var bytesPerRow: Int { frameBytesPerRow }
    package var pixelFormat: OSType { framePixelFormat }

    fileprivate init(entry: SurfaceEntry, pool: IOSurfaceFramePool) {
        surface = entry.surface
        frameWidth = entry.key.width
        frameHeight = entry.key.height
        frameBytesPerRow = entry.bytesPerRow
        framePixelFormat = entry.key.pixelFormat
        release = { [entry, weak pool] in
            pool?.recycle(entry)
        }
    }

    package init(
        surface: IOSurfaceRef,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: OSType,
        release: @escaping @Sendable () -> Void
    ) {
        self.surface = surface
        frameWidth = width
        frameHeight = height
        frameBytesPerRow = bytesPerRow
        framePixelFormat = pixelFormat
        self.release = release
    }

    deinit {
        release()
    }

    /// Copies the committed IOSurface contents for validation and CPU clients.
    /// Presentation code should consume the package-owned handle directly.
    package func copyPixels() -> Data? {
        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, .readOnly, &seed) == 0 else {
            return nil
        }
        defer { IOSurfaceUnlock(surface, .readOnly, &seed) }
        let baseAddress = IOSurfaceGetBaseAddress(surface)

        let rowBytes = frameWidth * 4
        var pixels = Data(count: rowBytes * frameHeight)
        pixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else {
                return
            }
            for row in 0..<frameHeight {
                destinationBase.advanced(by: row * rowBytes).copyMemory(
                    from: baseAddress.advanced(by: row * frameBytesPerRow),
                    byteCount: rowBytes
                )
            }
        }
        return pixels
    }

    /// Borrows the immutable revision bytes while the IOSurface is read-locked.
    /// The pointer is valid only for the synchronous duration of `body`.
    package func withLockedBytes<Result>(
        _ body: (UnsafeRawPointer, Int, Int) -> Result
    ) -> Result? {
        let (requiredBytes, overflow) = frameBytesPerRow.multipliedReportingOverflow(
            by: frameHeight
        )
        guard frameBytesPerRow >= 0,
              frameHeight >= 0,
              !overflow,
              requiredBytes <= IOSurfaceGetAllocSize(surface)
        else {
            return nil
        }
        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, .readOnly, &seed) == 0 else {
            return nil
        }
        defer { IOSurfaceUnlock(surface, .readOnly, &seed) }
        return body(
            IOSurfaceGetBaseAddress(surface),
            frameBytesPerRow,
            requiredBytes
        )
    }

    package func withIOSurface<Result, Failure: Error>(
        _ body: (IOSurfaceRef) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(surface)
    }
}

package final class IOSurfaceFramePool: Sendable {
    package static let shared = IOSurfaceFramePool(
        limits: .init(),
        allocationBudget: .shared
    )

    private struct State {
        var available: [FrameKey: [SurfaceEntry]] = [:]
        var allocatedFrames = 0
        var allocatedBytes = 0
        var inUseFrames = 0
    }

    private let limits: IOSurfaceFramePoolLimits
    private let allocationBudget: IOSurfaceAllocationBudget
    private let state = Mutex(State())

    package init(limits: IOSurfaceFramePoolLimits = .init()) {
        self.limits = limits
        allocationBudget = IOSurfaceAllocationBudget(maximumBytes: limits.maximumBytes)
    }

    private init(
        limits: IOSurfaceFramePoolLimits,
        allocationBudget: IOSurfaceAllocationBudget
    ) {
        self.limits = limits
        self.allocationBudget = allocationBudget
    }

    package func makeFrame(
        width: Int,
        height: Int,
        sourceBytesPerRow: Int,
        pixels: Data
    ) -> IOSurfaceFrame? {
        guard width > 0, height > 0 else {
            return nil
        }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (sourceByteCount, sourceSizeOverflow) = sourceBytesPerRow
            .multipliedReportingOverflow(by: height)
        let (minimumByteCount, minimumSizeOverflow) = rowBytes
            .multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sourceSizeOverflow, !minimumSizeOverflow,
              sourceBytesPerRow >= rowBytes,
              sourceByteCount == pixels.count,
              minimumByteCount <= limits.maximumBytes,
              limits.maximumFrames > 0
        else {
            return nil
        }

        let key = FrameKey(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        guard let entry = checkout(key: key, minimumByteCount: minimumByteCount) else {
            return nil
        }
        guard copy(
            pixels: pixels,
            sourceBytesPerRow: sourceBytesPerRow,
            into: entry
        ) else {
            recycle(entry)
            return nil
        }
        return IOSurfaceFrame(entry: entry, pool: self)
    }

    package func metrics() -> IOSurfaceFramePoolMetrics {
        state.withLock { state in
            IOSurfaceFramePoolMetrics(
                allocatedFrames: state.allocatedFrames,
                availableFrames: state.available.values.reduce(0) { $0 + $1.count },
                inUseFrames: state.inUseFrames,
                allocatedBytes: state.allocatedBytes
            )
        }
    }

    /// Releases cached fallback frames so the process-shared revisioned pool
    /// can reclaim the common IOSurface budget under pressure. In-use leases
    /// remain immutable and are never revoked.
    package func purgeAvailable() {
        var discarded: [SurfaceEntry] = state.withLock { state in
            let entries = state.available.values.flatMap { $0 }
            state.available.removeAll(keepingCapacity: false)
            state.allocatedFrames -= entries.count
            state.allocatedBytes -= entries.reduce(0) { $0 + $1.allocationSize }
            return entries
        }
        // Drop entries after releasing the pool lock. Their deinitializers
        // acquire the process-wide allocation-budget lock.
        discarded.removeAll(keepingCapacity: false)
    }

    private func checkout(key: FrameKey, minimumByteCount: Int) -> SurfaceEntry? {
        state.withLock { state in
            if var entries = state.available[key], let entry = entries.popLast() {
                state.available[key] = entries.isEmpty ? nil : entries
                state.inUseFrames += 1
                return entry
            }

            while state.allocatedFrames >= limits.maximumFrames
                || !fitsWithinByteLimit(
                    current: state.allocatedBytes,
                    adding: minimumByteCount
                )
            {
                guard evictOneAvailable(from: &state) else {
                    return nil
                }
            }

            let properties: [CFString: Any] = [
                kIOSurfaceWidth: key.width,
                kIOSurfaceHeight: key.height,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfacePixelFormat: key.pixelFormat,
            ]
            guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
                return nil
            }
            let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
            let allocationSize = IOSurfaceGetAllocSize(surface)
            let (coveredBytes, coveredBytesOverflow) = bytesPerRow
                .multipliedReportingOverflow(by: key.height)
            guard bytesPerRow >= key.width * 4,
                  !coveredBytesOverflow,
                  coveredBytes <= allocationSize,
                  allocationBudget.reserve(allocationSize)
            else {
                return nil
            }
            let entry = SurfaceEntry(
                key: key,
                surface: surface,
                allocationBudget: allocationBudget
            )
            while state.allocatedFrames >= limits.maximumFrames
                || !fitsWithinByteLimit(
                    current: state.allocatedBytes,
                    adding: entry.allocationSize
                )
            {
                guard evictOneAvailable(from: &state) else {
                    return nil
                }
            }
            state.allocatedFrames += 1
            state.allocatedBytes += entry.allocationSize
            state.inUseFrames += 1
            return entry
        }
    }

    private func fitsWithinByteLimit(current: Int, adding: Int) -> Bool {
        let (total, overflow) = current.addingReportingOverflow(adding)
        return !overflow && total <= limits.maximumBytes
    }

    private func evictOneAvailable(from state: inout State) -> Bool {
        guard let key = state.available.keys.first,
              var entries = state.available[key],
              let entry = entries.popLast()
        else {
            return false
        }
        state.available[key] = entries.isEmpty ? nil : entries
        state.allocatedFrames -= 1
        state.allocatedBytes -= entry.allocationSize
        return true
    }

    private func copy(
        pixels: Data,
        sourceBytesPerRow: Int,
        into entry: SurfaceEntry
    ) -> Bool {
        var seed: UInt32 = 0
        guard IOSurfaceLock(entry.surface, [], &seed) == 0 else {
            return false
        }
        defer { IOSurfaceUnlock(entry.surface, [], &seed) }
        let destination = IOSurfaceGetBaseAddress(entry.surface)

        let rowBytes = entry.key.width * 4
        pixels.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else {
                return
            }
            if sourceBytesPerRow == rowBytes, entry.bytesPerRow == rowBytes {
                destination.copyMemory(
                    from: sourceBase,
                    byteCount: rowBytes * entry.key.height
                )
                return
            }
            destination.initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: entry.bytesPerRow * entry.key.height
            )
            for row in 0..<entry.key.height {
                destination.advanced(by: row * entry.bytesPerRow).copyMemory(
                    from: sourceBase.advanced(by: row * sourceBytesPerRow),
                    byteCount: rowBytes
                )
            }
        }
        return true
    }

    fileprivate func recycle(_ entry: SurfaceEntry) {
        state.withLock { state in
            precondition(state.inUseFrames > 0)
            state.inUseFrames -= 1
            state.available[entry.key, default: []].append(entry)
        }
    }
}
