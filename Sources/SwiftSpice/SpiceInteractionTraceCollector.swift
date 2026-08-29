import Darwin
import Foundation
import Synchronization

package enum SpiceInteractionTraceCollectionError: Error, Sendable, Equatable {
    case captureAlreadyActive
    case captureAlreadyFinished
    case presentationWaitAlreadyRegistered
    case outputDirectoryUnavailable
    case outputIsSymbolicLink
    case invalidExistingJSONL
    case recordTooLarge(actual: Int, maximum: Int)
    case outputTooLarge(actual: Int, maximum: Int)
    case fileOperationFailed(operation: String, code: Int32)
}

package final class SpiceInteractionPresentationWaiter: @unchecked Sendable {
    private enum Waiting: @unchecked Sendable {
        case reserved(id: UUID, cancelled: Bool)
        case registered(id: UUID, CheckedContinuation<SpiceInteractionFrameIdentity, any Error>)
    }

    package struct Resumption: @unchecked Sendable {
        fileprivate let continuation: CheckedContinuation<SpiceInteractionFrameIdentity, any Error>
        fileprivate let result: Result<SpiceInteractionFrameIdentity, any Error>

        package func resume() {
            continuation.resume(with: result)
        }
    }

    private enum Phase: @unchecked Sendable {
        case active(Waiting?)
        case completed(SpiceInteractionFrameIdentity)
        case finished
    }

    private let phase = Mutex<Phase>(.active(nil))

    package func wait(
        waiterRegistered: (@Sendable () -> Void)?
    ) async throws -> SpiceInteractionFrameIdentity {
        let reservationID = UUID()
        if let immediate = try reserve(reservationID) {
            return immediate
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (registered, resumption) = register(
                    reservationID,
                    continuation: continuation,
                    taskIsCancelled: Task.isCancelled
                )
                if registered {
                    waiterRegistered?()
                }
                resumption?.resume()
            }
        } onCancel: {
            self.cancel(reservationID)?.resume()
        }
    }

    package func prepareCompletion(
        _ identity: SpiceInteractionFrameIdentity
    ) -> Resumption? {
        phase.withLock { phase in
            guard case let .active(waiting) = phase else { return nil }
            phase = .completed(identity)
            guard case let .registered(_, continuation) = waiting else { return nil }
            return Resumption(continuation: continuation, result: .success(identity))
        }
    }

    package func prepareFinish() -> Resumption? {
        phase.withLock { phase in
            guard case let .active(waiting) = phase else { return nil }
            phase = .finished
            guard case let .registered(_, continuation) = waiting else { return nil }
            return Resumption(
                continuation: continuation,
                result: .failure(SpiceInteractionTraceCollectionError.captureAlreadyFinished)
            )
        }
    }

    private func reserve(
        _ reservationID: UUID
    ) throws -> SpiceInteractionFrameIdentity? {
        try phase.withLock { phase in
            switch phase {
            case let .completed(identity):
                return identity
            case .finished:
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            case let .active(waiting):
                guard waiting == nil else {
                    throw SpiceInteractionTraceCollectionError.presentationWaitAlreadyRegistered
                }
                phase = .active(.reserved(id: reservationID, cancelled: false))
                return nil
            }
        }
    }

    private func register(
        _ reservationID: UUID,
        continuation: CheckedContinuation<SpiceInteractionFrameIdentity, any Error>,
        taskIsCancelled: Bool
    ) -> (registered: Bool, resumption: Resumption?) {
        phase.withLock { phase in
            switch phase {
            case let .completed(identity):
                return (
                    false,
                    Resumption(continuation: continuation, result: .success(identity))
                )
            case .finished:
                return (
                    false,
                    Resumption(
                        continuation: continuation,
                        result: .failure(
                            SpiceInteractionTraceCollectionError.captureAlreadyFinished
                        )
                    )
                )
            case let .active(waiting):
                guard case let .reserved(id, wasCancelled) = waiting,
                      id == reservationID else {
                    return (
                        false,
                        Resumption(
                            continuation: continuation,
                            result: .failure(
                                SpiceInteractionTraceCollectionError.captureAlreadyFinished
                            )
                        )
                    )
                }
                if wasCancelled || taskIsCancelled {
                    phase = .active(nil)
                    return (
                        false,
                        Resumption(
                            continuation: continuation,
                            result: .failure(CancellationError())
                        )
                    )
                }
                phase = .active(.registered(id: reservationID, continuation))
                return (true, nil)
            }
        }
    }

    private func cancel(_ reservationID: UUID) -> Resumption? {
        phase.withLock { phase in
            guard case let .active(waiting) = phase else { return nil }
            switch waiting {
            case let .reserved(id, _) where id == reservationID:
                phase = .active(.reserved(id: id, cancelled: true))
                return nil
            case let .registered(id, continuation) where id == reservationID:
                phase = .active(nil)
                return Resumption(
                    continuation: continuation,
                    result: .failure(CancellationError())
                )
            default:
                return nil
            }
        }
    }
}

/// A cross-process serialized, bounded writer for normalized interaction
/// evidence. Publication replaces the file with a fully fsynced mode-0600
/// inode, so a crash cannot expose a partial JSON line. An exact existing line
/// is treated as an idempotent retry after an uncertain directory-fsync result.
package final class SpiceInteractionTraceJSONLWriter: Sendable {
    package static let maximumRecordBytes = 64 * 1024
    package static let maximumFileBytes = 16 * 1024 * 1024

    private let outputURL: URL

    package init(outputURL: URL) {
        self.outputURL = outputURL
    }

    package func append(_ record: SpiceInteractionTraceRecord) throws {
        var encoded = try JSONEncoder.interactionTrace.encode(record)
        encoded.append(0x0A)
        guard encoded.count <= Self.maximumRecordBytes else {
            throw SpiceInteractionTraceCollectionError.recordTooLarge(
                actual: encoded.count,
                maximum: Self.maximumRecordBytes
            )
        }

        let directoryURL = outputURL.deletingLastPathComponent()
        var directoryStatus = stat()
        guard lstat(directoryURL.path, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR else {
            throw SpiceInteractionTraceCollectionError.outputDirectoryUnavailable
        }

        let lockURL = directoryURL.appendingPathComponent(
            ".\(outputURL.lastPathComponent).lock",
            isDirectory: false
        )
        let lockDescriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard lockDescriptor >= 0 else {
            if errno == ELOOP {
                throw SpiceInteractionTraceCollectionError.outputIsSymbolicLink
            }
            throw operationError("open_lock")
        }
        defer { Darwin.close(lockDescriptor) }
        guard fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw operationError("chmod_lock")
        }
        try lock(lockDescriptor)
        defer { unlock(lockDescriptor) }

        let existing = try readExistingOutput()
        if existing.split(separator: 0x0A).contains(encoded.dropLast()) {
            guard fsyncDirectory(directoryURL) else {
                throw operationError("fsync_directory")
            }
            return
        }
        let (totalBytes, overflow) = existing.count.addingReportingOverflow(encoded.count)
        guard !overflow, totalBytes <= Self.maximumFileBytes else {
            throw SpiceInteractionTraceCollectionError.outputTooLarge(
                actual: overflow ? Int.max : totalBytes,
                maximum: Self.maximumFileBytes
            )
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let temporaryDescriptor = Darwin.open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard temporaryDescriptor >= 0 else {
            throw operationError("open_temporary")
        }
        var removeTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if removeTemporary {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }
        guard fchmod(temporaryDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw operationError("chmod_temporary")
        }
        try writeAll(existing, to: temporaryDescriptor)
        try writeAll(encoded, to: temporaryDescriptor)
        guard fsync(temporaryDescriptor) == 0 else {
            throw operationError("fsync_temporary")
        }
        guard Darwin.rename(temporaryURL.path, outputURL.path) == 0 else {
            throw operationError("replace_output")
        }
        removeTemporary = false
        guard fsyncDirectory(directoryURL) else {
            throw operationError("fsync_directory")
        }
    }

    private func readExistingOutput() throws -> Data {
        let descriptor = Darwin.open(outputURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            guard errno == ENOENT else {
                if errno == ELOOP {
                    throw SpiceInteractionTraceCollectionError.outputIsSymbolicLink
                }
                throw operationError("open_output")
            }
            return Data()
        }
        defer { Darwin.close(descriptor) }
        var outputStatus = stat()
        guard fstat(descriptor, &outputStatus) == 0 else {
            throw operationError("inspect_output")
        }
        guard outputStatus.st_mode & S_IFMT == S_IFREG,
              outputStatus.st_size >= 0,
              UInt64(outputStatus.st_size) <= UInt64(Self.maximumFileBytes) else {
            throw SpiceInteractionTraceCollectionError.outputTooLarge(
                actual: outputStatus.st_size > Int.max ? Int.max : Int(outputStatus.st_size),
                maximum: Self.maximumFileBytes
            )
        }
        let data = try readAll(
            from: descriptor,
            expectedCount: Int(outputStatus.st_size)
        )
        guard data.isEmpty || data.last == 0x0A else {
            throw SpiceInteractionTraceCollectionError.invalidExistingJSONL
        }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeLast() }
        for line in lines {
            guard !line.isEmpty else {
                throw SpiceInteractionTraceCollectionError.invalidExistingJSONL
            }
            guard line.count + 1 <= Self.maximumRecordBytes else {
                throw SpiceInteractionTraceCollectionError.invalidExistingJSONL
            }
            do {
                let record = try JSONDecoder().decode(
                    SpiceInteractionTraceRecord.self,
                    from: line
                )
                guard try JSONEncoder.interactionTrace.encode(record) == Data(line) else {
                    throw SpiceInteractionTraceCollectionError.invalidExistingJSONL
                }
            } catch {
                throw SpiceInteractionTraceCollectionError.invalidExistingJSONL
            }
        }
        return data
    }

    private func readAll(from descriptor: Int32, expectedCount: Int) throws -> Data {
        var data = Data(count: expectedCount + 1)
        let finalCount = try data.withUnsafeMutableBytes { bytes -> Int in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw operationError("read_output") }
                if result == 0 { break }
                offset += result
            }
            return offset
        }
        guard finalCount == expectedCount else {
            throw SpiceInteractionTraceCollectionError.invalidExistingJSONL
        }
        data.removeSubrange(expectedCount..<data.count)
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw operationError("write_temporary") }
                offset += result
            }
        }
    }

    private func lock(_ descriptor: Int32) throws {
        var operation = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        while Darwin.fcntl(descriptor, F_SETLKW, &operation) != 0 {
            guard errno == EINTR else { throw operationError("lock") }
        }
    }

    private func unlock(_ descriptor: Int32) {
        var operation = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_UNLCK),
            l_whence: Int16(SEEK_SET)
        )
        _ = Darwin.fcntl(descriptor, F_SETLK, &operation)
    }

    private func fsyncDirectory(_ directoryURL: URL) -> Bool {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return fsync(descriptor) == 0
    }

    private func operationError(_ operation: String) -> SpiceInteractionTraceCollectionError {
        .fileOperationFailed(operation: operation, code: errno)
    }
}

package final class SpiceInteractionTraceCapture: Sendable {
    private enum Phase: Sendable {
        case active
        case pending(SpiceInteractionTraceRecord)
        case appended(SpiceInteractionTraceRecord)
    }

    private struct State: Sendable {
        var phase: Phase = .active
    }

    private let presentationDiagnostics: SpicePresentationDiagnostics
    private let writer: SpiceInteractionTraceJSONLWriter
    private let assembler: SpiceInteractionTraceAssembler
    private let presentationWaiter: SpiceInteractionPresentationWaiter
    private let evidenceWillCommit: (@Sendable () -> Void)?
    private let state = Mutex(State())
    private let appendLock = Mutex<Void>(())

    package convenience init(
        session: SpiceSession,
        writer: SpiceInteractionTraceJSONLWriter,
        pairId: String,
        version: String,
        runId: String,
        order: UInt64,
        actionClass: SpiceInteractionActionClass,
        token: String,
        checksum: UInt32,
        evidenceWillCommit: (@Sendable () -> Void)? = nil
    ) throws {
        try self.init(
            presentationDiagnostics: session.presentationDiagnostics,
            writer: writer,
            pairId: pairId,
            version: version,
            runId: runId,
            order: order,
            actionClass: actionClass,
            token: token,
            checksum: checksum,
            evidenceWillCommit: evidenceWillCommit
        )
    }

    package init(
        presentationDiagnostics: SpicePresentationDiagnostics,
        writer: SpiceInteractionTraceJSONLWriter,
        pairId: String,
        version: String,
        runId: String,
        order: UInt64,
        actionClass: SpiceInteractionActionClass,
        token: String,
        checksum: UInt32,
        evidenceWillCommit: (@Sendable () -> Void)? = nil
    ) throws {
        self.presentationDiagnostics = presentationDiagnostics
        self.writer = writer
        self.evidenceWillCommit = evidenceWillCommit
        let presentationWaiter = SpiceInteractionPresentationWaiter()
        self.presentationWaiter = presentationWaiter
        assembler = SpiceInteractionTraceAssembler(
            pairId: pairId,
            version: version,
            runId: runId,
            order: order,
            actionClass: actionClass,
            token: token,
            checksum: checksum,
            presentationWaiter: presentationWaiter
        )
        guard presentationDiagnostics.installInteractionTraceAssembler(assembler) else {
            throw SpiceInteractionTraceCollectionError.captureAlreadyActive
        }
    }

    deinit {
        presentationDiagnostics.removeInteractionTraceAssembler(assembler)
        presentationWaiter.prepareFinish()?.resume()
    }

    package func recordHostEvidence(
        scheduledNs: UInt64,
        hostInputNs: UInt64,
        sendStartedNs: UInt64,
        sendCompletedNs: UInt64,
        motionAckNs: UInt64? = nil
    ) throws {
        try withActiveCapture {
            assembler.recordHostEvidence(
                scheduledNs: scheduledNs,
                hostInputNs: hostInputNs,
                sendStartedNs: sendStartedNs,
                sendCompletedNs: sendCompletedNs,
                motionAckNs: motionAckNs
            )
        }
    }

    package func recordHostInput(
        scheduledNs: UInt64,
        hostInputNs: UInt64,
        sendStartedNs: UInt64
    ) throws {
        try withActiveCapture {
            assembler.recordHostInput(
                scheduledNs: scheduledNs,
                hostInputNs: hostInputNs,
                sendStartedNs: sendStartedNs
            )
        }
    }

    package func recordSendCompleted(
        at nanoseconds: UInt64,
        motionAckNs: UInt64? = nil
    ) throws {
        try withActiveCapture {
            assembler.recordSendCompleted(
                at: nanoseconds,
                motionAckNs: motionAckNs
            )
        }
    }

    package func recordMotionAcknowledged(at nanoseconds: UInt64) throws {
        try withActiveCapture {
            assembler.recordMotionAcknowledged(at: nanoseconds)
        }
    }

    package func recordGuestEvidence(
        receivedNs: UInt64,
        drawnNs: UInt64,
        markerRevision: UInt64
    ) throws {
        try withActiveCapture {
            assembler.recordGuestEvidence(
                receivedNs: receivedNs,
                drawnNs: drawnNs,
                markerRevision: markerRevision
            )
        }
    }

    /// Suspends without polling until this capture's selected, committed
    /// delivery is accepted by the AppKit presented callback. The wait neither
    /// finishes nor appends the capture, and an already accepted presentation
    /// is returned immediately.
    package func waitForExactPresentation(
        waiterRegistered: (@Sendable () -> Void)? = nil
    ) async throws -> SpiceInteractionFrameIdentity {
        try state.withLock { state in
            guard case .active = state.phase else {
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            }
        }
        return try await presentationWaiter.wait(waiterRegistered: waiterRegistered)
    }

    @discardableResult
    package func finish(
        invalidReason: String? = nil
    ) throws -> SpiceInteractionTraceRecord {
        let (record, waitResumption) = try state.withLock { state in
            switch state.phase {
            case .active:
                presentationDiagnostics.removeInteractionTraceAssembler(assembler)
                let record = assembler.finish(invalidReason: invalidReason)
                state.phase = .pending(record)
                return (record, presentationWaiter.prepareFinish())
            case let .pending(record):
                return (record, nil)
            case .appended:
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            }
        }
        waitResumption?.resume()
        return try appendLock.withLock { _ in
            if case .appended = state.withLock({ $0.phase }) {
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            }
            try writer.append(record)
            state.withLock { $0.phase = .appended(record) }
            return record
        }
    }

    private func withActiveCapture(_ body: () -> Void) throws {
        try state.withLock { state in
            guard case .active = state.phase else {
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            }
            evidenceWillCommit?()
            body()
        }
    }
}

private extension JSONEncoder {
    static var interactionTrace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
