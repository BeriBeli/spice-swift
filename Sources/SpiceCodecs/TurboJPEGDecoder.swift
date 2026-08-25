import CoreVideo
import Foundation
import SpiceCodecInterop

package struct SpiceJPEGDecoder: SpiceImageDecoder {
    package nonisolated let format = SpiceImageFormat.jpeg
    private let limits: SpiceJPEGDecodeLimits
    private let backend = TurboJPEGInterop()

    package init(limits: SpiceJPEGDecodeLimits = .init()) {
        self.limits = limits
    }

    @concurrent
    package func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        guard !payload.isEmpty else {
            throw .emptyPayload
        }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(
                actual: payload.count,
                maximum: limits.maximumEncodedBytes
            )
        }
        guard descriptor.width > 0, descriptor.height > 0,
              descriptor.width <= limits.maximumDimension,
              descriptor.height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: descriptor.width, height: descriptor.height)
        }
        let (bytesPerRow, rowOverflow) = descriptor.width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = bytesPerRow.multipliedReportingOverflow(
            by: descriptor.height
        )
        guard !rowOverflow, !sizeOverflow else {
            throw .integerOverflow
        }
        guard byteCount <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(actual: byteCount, maximum: limits.maximumDecodedBytes)
        }

        let pixels: Data
        do {
            pixels = try backend.decodeBGRA(
                payload: payload,
                expectedWidth: descriptor.width,
                expectedHeight: descriptor.height,
                bytesPerRow: bytesPerRow,
                outputByteCount: byteCount
            )
        } catch let error {
            switch error {
            case let .dimensionMismatch(actualWidth, actualHeight):
                throw .dimensionMismatch(
                    expectedWidth: descriptor.width,
                    expectedHeight: descriptor.height,
                    actualWidth: actualWidth,
                    actualHeight: actualHeight
                )
            default:
                throw .backendFailure(String(describing: error))
            }
        }
        return SpiceDecodedImage(
            width: descriptor.width,
            height: descriptor.height,
            bytesPerRow: bytesPerRow,
            pixelsBGRA: pixels
        )
    }
}

package struct SpiceMJPEGDecodeLimiterDiagnostics: Sendable, Equatable {
    package let activeDecodeCount: Int
    package let queuedDecodeCount: Int
    package let peakDecodeCount: Int
}

/// A SPICE session creates one limiter and shares it across all display channels
/// and MJPEG stream decoders. This bounds libturbojpeg work without blocking a
/// cooperative executor thread on a semaphore.
package actor SpiceMJPEGDecodeLimiter {
    private let maximumConcurrent: Int
    private var activeDecodeCount = 0
    private var peakDecodeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init(maximumConcurrent: Int = 2) {
        self.maximumConcurrent = max(1, maximumConcurrent)
    }

    package func acquire() async {
        if activeDecodeCount < maximumConcurrent {
            activeDecodeCount += 1
            peakDecodeCount = max(peakDecodeCount, activeDecodeCount)
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    package func release() {
        if waiters.isEmpty {
            activeDecodeCount -= 1
            return
        }
        let continuation = waiters.removeFirst()
        continuation.resume()
    }

    package func diagnosticsSnapshot() -> SpiceMJPEGDecodeLimiterDiagnostics {
        SpiceMJPEGDecodeLimiterDiagnostics(
            activeDecodeCount: activeDecodeCount,
            queuedDecodeCount: waiters.count,
            peakDecodeCount: peakDecodeCount
        )
    }
}

package struct SpiceMJPEGDecoderDiagnostics: Sendable, Equatable {
    package let handleCreationCount: UInt64
    package let decodedFrameCount: UInt64
    package let ioSurfaceFrameCount: UInt64
    package let dataFallbackCount: UInt64
    package let ioSurfaceAllocationCount: UInt64
    package let peakBuffersInUse: Int
    package let decodeLimiter: SpiceMJPEGDecodeLimiterDiagnostics
}

/// An immutable IOSurface-backed fast-MJPEG result. Retaining this frame owns a
/// pool lease; releasing it returns the CVPixelBuffer to the stream's bounded
/// three-slot pool after Metal or a CPU fallback has finished reading it.
package final class SpiceMJPEGFrame: SpiceDecodedVideoFrame, @unchecked Sendable {
    package let width: Int
    package let height: Int
    package let pixelFormat = SpiceDecodedVideoPixelFormat.bgra8
    package let colorMatrix = SpiceVideoColorMatrix.unknown(nil)
    package let colorRange = SpiceVideoColorRange.full
    package let pixelBuffer: CVPixelBuffer

    private let lease: SpiceMJPEGBufferLease

    fileprivate init(lease: SpiceMJPEGBufferLease) {
        self.lease = lease
        self.pixelBuffer = lease.pixelBuffer
        self.width = CVPixelBufferGetWidth(lease.pixelBuffer)
        self.height = CVPixelBufferGetHeight(lease.pixelBuffer)
    }

    package func copyBGRA() throws(SpiceCodecError) -> SpiceDecodedImage {
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !countOverflow else {
            throw .integerOverflow
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw .backendFailure("MJPEG CVPixelBuffer lock status \(lockStatus)")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw .backendFailure("MJPEG CVPixelBuffer has no base address")
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sourceStride >= rowBytes else {
            throw .backendFailure("MJPEG CVPixelBuffer stride is shorter than one row")
        }
        var pixels = Data(count: byteCount)
        pixels.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else { return }
            for row in 0..<height {
                destination.advanced(by: row * rowBytes).copyMemory(
                    from: source.advanced(by: row * sourceStride),
                    byteCount: rowBytes
                )
            }
        }
        return SpiceDecodedImage(
            width: width,
            height: height,
            bytesPerRow: rowBytes,
            pixelsBGRA: pixels
        )
    }
}

/// Per-SPICE-stream MJPEG decoder. It keeps one TurboJPEG handle warm, writes
/// directly into IOSurface-backed BGRA buffers when one is immediately free,
/// and uses a bounded Data decode rather than waiting when all three are leased.
package actor SpiceMJPEGStreamDecoder {
    private let limits: SpiceJPEGDecodeLimits
    private let limiter: SpiceMJPEGDecodeLimiter
    private let pool: SpiceMJPEGBufferPool
    private var backend: TurboJPEGDecoderHandle?
    private var decodedFrameCount: UInt64 = 0
    private var ioSurfaceFrameCount: UInt64 = 0
    private var dataFallbackCount: UInt64 = 0

    package init(
        limits: SpiceJPEGDecodeLimits = .init(),
        limiter: SpiceMJPEGDecodeLimiter,
        poolCapacity: Int = 3
    ) throws(SpiceCodecError) {
        self.limits = limits
        self.limiter = limiter
        self.pool = SpiceMJPEGBufferPool(capacity: min(3, max(0, poolCapacity)))
        do {
            self.backend = try TurboJPEGDecoderHandle()
        } catch {
            throw .backendFailure(String(describing: error))
        }
    }

    package func decodeVideoFrame(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> any SpiceDecodedVideoFrame {
        let layout = try validatedLayout(descriptor: descriptor, payload: payload)
        guard backend != nil else {
            throw .cancelled
        }

        await limiter.acquire()
        let result: Result<any SpiceDecodedVideoFrame, SpiceCodecError>
        if Task.isCancelled {
            result = .failure(.cancelled)
        } else {
            do {
                result = .success(try decodeWithPermit(
                    descriptor: descriptor,
                    payload: payload,
                    layout: layout
                ))
            } catch {
                result = .failure(error)
            }
        }
        await limiter.release()
        return try result.get()
    }

    package func diagnosticsSnapshot() async -> SpiceMJPEGDecoderDiagnostics {
        let poolDiagnostics = pool.diagnosticsSnapshot()
        return SpiceMJPEGDecoderDiagnostics(
            handleCreationCount: 1,
            decodedFrameCount: decodedFrameCount,
            ioSurfaceFrameCount: ioSurfaceFrameCount,
            dataFallbackCount: dataFallbackCount,
            ioSurfaceAllocationCount: poolDiagnostics.allocationCount,
            peakBuffersInUse: poolDiagnostics.peakBuffersInUse,
            decodeLimiter: await limiter.diagnosticsSnapshot()
        )
    }

    package func close() {
        backend = nil
        pool.discardAvailableBuffers()
    }

    private func decodeWithPermit(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data,
        layout: (bytesPerRow: Int, byteCount: Int)
    ) throws(SpiceCodecError) -> any SpiceDecodedVideoFrame {
        guard let backend else {
            throw .cancelled
        }
        if let lease = pool.acquire(width: descriptor.width, height: descriptor.height) {
            let buffer = lease.pixelBuffer
            let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
            if lockStatus == kCVReturnSuccess {
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                    let (outputByteCount, overflow) = bytesPerRow.multipliedReportingOverflow(
                        by: descriptor.height
                    )
                    if !overflow {
                        do {
                            try backend.decodeBGRA(
                                payload: payload,
                                expectedWidth: descriptor.width,
                                expectedHeight: descriptor.height,
                                bytesPerRow: bytesPerRow,
                                outputByteCount: outputByteCount,
                                mode: .mjpegFast,
                                into: UnsafeMutableRawBufferPointer(
                                    start: baseAddress,
                                    count: outputByteCount
                                )
                            )
                            decodedFrameCount &+= 1
                            ioSurfaceFrameCount &+= 1
                            return SpiceMJPEGFrame(lease: lease)
                        } catch {
                            throw Self.codecError(
                                from: error,
                                expectedWidth: descriptor.width,
                                expectedHeight: descriptor.height
                            )
                        }
                    }
                }
            }
            // The lease is returned as this scope exits. Fall through to the
            // bounded Data path without waiting or allocating an extra surface.
        }

        let pixels: Data
        do {
            pixels = try backend.decodeBGRAData(
                payload: payload,
                expectedWidth: descriptor.width,
                expectedHeight: descriptor.height,
                bytesPerRow: layout.bytesPerRow,
                outputByteCount: layout.byteCount,
                mode: .mjpegFast
            )
        } catch {
            throw Self.codecError(
                from: error,
                expectedWidth: descriptor.width,
                expectedHeight: descriptor.height
            )
        }
        decodedFrameCount &+= 1
        dataFallbackCount &+= 1
        return SpiceDecodedImage(
            width: descriptor.width,
            height: descriptor.height,
            bytesPerRow: layout.bytesPerRow,
            pixelsBGRA: pixels
        )
    }

    private func validatedLayout(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) throws(SpiceCodecError) -> (bytesPerRow: Int, byteCount: Int) {
        guard !payload.isEmpty else {
            throw .emptyPayload
        }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(
                actual: payload.count,
                maximum: limits.maximumEncodedBytes
            )
        }
        guard descriptor.width > 0, descriptor.height > 0,
              descriptor.width <= limits.maximumDimension,
              descriptor.height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: descriptor.width, height: descriptor.height)
        }
        let (bytesPerRow, rowOverflow) = descriptor.width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = bytesPerRow.multipliedReportingOverflow(
            by: descriptor.height
        )
        guard !rowOverflow, !sizeOverflow else {
            throw .integerOverflow
        }
        guard byteCount <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(actual: byteCount, maximum: limits.maximumDecodedBytes)
        }
        return (bytesPerRow, byteCount)
    }

    private nonisolated static func codecError(
        from error: TurboJPEGInteropError,
        expectedWidth: Int,
        expectedHeight: Int
    ) -> SpiceCodecError {
        switch error {
        case let .dimensionMismatch(actualWidth, actualHeight):
            .dimensionMismatch(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        default:
            .backendFailure(String(describing: error))
        }
    }
}

private struct SpiceMJPEGBufferPoolDiagnostics {
    let allocationCount: UInt64
    let peakBuffersInUse: Int
}

private final class SpiceMJPEGBufferLease: @unchecked Sendable {
    let id: UInt64
    let pixelBuffer: CVPixelBuffer
    private let pool: SpiceMJPEGBufferPool

    init(id: UInt64, pixelBuffer: CVPixelBuffer, pool: SpiceMJPEGBufferPool) {
        self.id = id
        self.pixelBuffer = pixelBuffer
        self.pool = pool
    }

    deinit {
        pool.release(id: id)
    }
}

private final class SpiceMJPEGBufferPool: @unchecked Sendable {
    private struct Entry {
        let id: UInt64
        let width: Int
        let height: Int
        let pixelBuffer: CVPixelBuffer
        var inUse: Bool
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextID: UInt64 = 1
    private var allocationCount: UInt64 = 0
    private var peakBuffersInUse = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    func acquire(width: Int, height: Int) -> SpiceMJPEGBufferLease? {
        lock.lock()
        defer { lock.unlock() }

        if let index = entries.firstIndex(where: {
            !$0.inUse && $0.width == width && $0.height == height
        }) {
            entries[index].inUse = true
            recordPeakLocked()
            return SpiceMJPEGBufferLease(
                id: entries[index].id,
                pixelBuffer: entries[index].pixelBuffer,
                pool: self
            )
        }

        // Geometry changes can discard an idle slot, but an in-flight frame is
        // never stolen. If all three are leased, return nil immediately.
        if entries.count >= capacity,
           let replaceable = entries.firstIndex(where: { !$0.inUse })
        {
            entries.remove(at: replaceable)
        }
        guard entries.count < capacity,
              let pixelBuffer = Self.makePixelBuffer(width: width, height: height)
        else {
            return nil
        }
        let id = nextID
        nextID &+= 1
        allocationCount &+= 1
        entries.append(Entry(
            id: id,
            width: width,
            height: height,
            pixelBuffer: pixelBuffer,
            inUse: true
        ))
        recordPeakLocked()
        return SpiceMJPEGBufferLease(id: id, pixelBuffer: pixelBuffer, pool: self)
    }

    func release(id: UInt64) {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].inUse = false
        }
        lock.unlock()
    }

    func discardAvailableBuffers() {
        lock.lock()
        entries.removeAll(where: { !$0.inUse })
        lock.unlock()
    }

    func diagnosticsSnapshot() -> SpiceMJPEGBufferPoolDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return SpiceMJPEGBufferPoolDiagnostics(
            allocationCount: allocationCount,
            peakBuffersInUse: peakBuffersInUse
        )
    }

    private func recordPeakLocked() {
        peakBuffersInUse = max(peakBuffersInUse, entries.count(where: \.inUse))
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferBytesPerRowAlignmentKey: 64,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess,
              let pixelBuffer,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil
        else {
            return nil
        }
        return pixelBuffer
    }
}
