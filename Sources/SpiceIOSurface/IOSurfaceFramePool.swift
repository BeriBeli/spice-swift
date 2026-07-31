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

    init(key: FrameKey, surface: IOSurfaceRef) {
        self.key = key
        self.surface = surface
        self.bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        self.allocationSize = IOSurfaceGetAllocSize(surface)
    }
}

package final class IOSurfaceFrame: @unchecked Sendable {
    private let entry: SurfaceEntry
    private let pool: IOSurfaceFramePool

    package var id: UInt32 { IOSurfaceGetID(entry.surface) }
    package var width: Int { entry.key.width }
    package var height: Int { entry.key.height }
    package var bytesPerRow: Int { entry.bytesPerRow }
    package var pixelFormat: OSType { entry.key.pixelFormat }

    fileprivate init(entry: SurfaceEntry, pool: IOSurfaceFramePool) {
        self.entry = entry
        self.pool = pool
    }

    deinit {
        pool.recycle(entry)
    }

    /// Copies the committed IOSurface contents for validation and CPU clients.
    /// Presentation code should consume the package-owned handle directly.
    package func copyPixels() -> Data? {
        var seed: UInt32 = 0
        guard IOSurfaceLock(entry.surface, .readOnly, &seed) == 0 else {
            return nil
        }
        defer { IOSurfaceUnlock(entry.surface, .readOnly, &seed) }
        let baseAddress = IOSurfaceGetBaseAddress(entry.surface)

        let rowBytes = entry.key.width * 4
        var pixels = Data(count: rowBytes * entry.key.height)
        pixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else {
                return
            }
            for row in 0..<entry.key.height {
                destinationBase.advanced(by: row * rowBytes).copyMemory(
                    from: baseAddress.advanced(by: row * entry.bytesPerRow),
                    byteCount: rowBytes
                )
            }
        }
        return pixels
    }

    package func withIOSurface<Result, Failure: Error>(
        _ body: (IOSurfaceRef) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(entry.surface)
    }
}

package final class IOSurfaceFramePool: Sendable {
    private struct State {
        var available: [FrameKey: [SurfaceEntry]] = [:]
        var allocatedFrames = 0
        var allocatedBytes = 0
        var inUseFrames = 0
    }

    private let limits: IOSurfaceFramePoolLimits
    private let state = Mutex(State())

    package init(limits: IOSurfaceFramePoolLimits = .init()) {
        self.limits = limits
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
            let entry = SurfaceEntry(key: key, surface: surface)
            let (coveredBytes, coveredBytesOverflow) = entry.bytesPerRow
                .multipliedReportingOverflow(by: key.height)
            guard entry.bytesPerRow >= key.width * 4,
                  !coveredBytesOverflow,
                  coveredBytes <= entry.allocationSize
            else {
                return nil
            }
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

        destination.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: entry.bytesPerRow * entry.key.height
        )
        let rowBytes = entry.key.width * 4
        pixels.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else {
                return
            }
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
