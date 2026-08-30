import Darwin
import Foundation

/// A bounded, cross-process serialized writer for canonical schema-2 records.
/// The parent directory and published inode are private, and publication uses
/// a fully-synced same-directory replacement so no partial JSON line is ever
/// visible at the output path.
package final class SpiceInteractionTraceJSONLWriter: Sendable {
    package static let maximumRecordBytes = 64 * 1_024
    package static let maximumFileBytes = 16 * 1_024 * 1_024

    private let outputURL: URL

    package init(outputURL: URL) {
        self.outputURL = outputURL
    }

    package func append(_ record: SpiceInteractionTraceRecord) throws {
        guard Self.isCanonicalAbsoluteFileURL(outputURL) else {
            throw SpiceInteractionTraceCollectionError.invalidOutputPath
        }
        var encoded = try JSONEncoder.interactionTrace.encode(record)
        encoded.append(0x0A)
        guard encoded.count <= Self.maximumRecordBytes else {
            throw SpiceInteractionTraceCollectionError.recordTooLarge(
                actual: encoded.count,
                maximum: Self.maximumRecordBytes
            )
        }

        let directoryURL = outputURL.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else {
            if errno == ELOOP {
                throw SpiceInteractionTraceCollectionError.outputIsSymbolicLink
            }
            throw operationError("open_directory")
        }
        defer { Darwin.close(directoryDescriptor) }
        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR else {
            throw SpiceInteractionTraceCollectionError.outputDirectoryUnavailable
        }
        guard fchmod(directoryDescriptor, S_IRWXU) == 0 else {
            throw operationError("chmod_directory")
        }

        let lockName = ".\(outputURL.lastPathComponent).lock"
        let lockDescriptor = Darwin.openat(
            directoryDescriptor,
            lockName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
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
        var lockStatus = stat()
        guard fstat(lockDescriptor, &lockStatus) == 0,
              lockStatus.st_mode & S_IFMT == S_IFREG else {
            throw SpiceInteractionTraceCollectionError.outputIsSymbolicLink
        }
        try lock(lockDescriptor)
        defer { unlock(lockDescriptor) }

        let existing = try readExistingOutput(
            directoryDescriptor: directoryDescriptor,
            outputName: outputURL.lastPathComponent
        )
        if existing.split(separator: 0x0A).contains(encoded.dropLast()) {
            guard fsync(directoryDescriptor) == 0 else {
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

        let temporaryName = ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp"
        let temporaryDescriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
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
                _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
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
        guard renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            outputURL.lastPathComponent
        ) == 0 else {
            throw operationError("replace_output")
        }
        removeTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            // The replacement may already be durable. An exact-line retry is
            // therefore intentionally idempotent rather than duplicating it.
            throw operationError("fsync_directory")
        }
    }

    private func readExistingOutput(
        directoryDescriptor: Int32,
        outputName: String
    ) throws -> Data {
        let descriptor = Darwin.openat(
            directoryDescriptor,
            outputName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
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
        guard outputStatus.st_mode & S_IFMT == S_IFREG else {
            throw SpiceInteractionTraceCollectionError.invalidOutputPath
        }
        guard outputStatus.st_size >= 0,
              UInt64(outputStatus.st_size) <= UInt64(Self.maximumFileBytes) else {
            throw SpiceInteractionTraceCollectionError.outputTooLarge(
                actual: outputStatus.st_size > Int.max ? Int.max : Int(outputStatus.st_size),
                maximum: Self.maximumFileBytes
            )
        }
        let data = try readAll(from: descriptor, expectedCount: Int(outputStatus.st_size))
        guard data.isEmpty || data.last == 0x0A else {
            throw SpiceInteractionTraceCollectionError.invalidExistingJSONL
        }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeLast() }
        for line in lines {
            guard !line.isEmpty,
                  line.count < Self.maximumRecordBytes else {
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
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw operationError("chmod_output")
        }
        return data
    }

    private func readAll(from descriptor: Int32, expectedCount: Int) throws -> Data {
        let (allocatedCount, overflow) = expectedCount.addingReportingOverflow(1)
        guard !overflow else {
            throw SpiceInteractionTraceCollectionError.invalidExistingJSONL
        }
        var data = Data(count: allocatedCount)
        let finalCount = try data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
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
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
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

    private static func isCanonicalAbsoluteFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.baseURL == nil,
              !url.hasDirectoryPath else { return false }
        let path = url.path
        return path.hasPrefix("/")
            && url.relativePath == path
            && path != "/"
            && !path.hasSuffix("/")
            && !path.contains("//")
            && !path.split(separator: "/").contains(".")
            && !path.split(separator: "/").contains("..")
            && !url.lastPathComponent.isEmpty
    }

    private func operationError(
        _ operation: String
    ) -> SpiceInteractionTraceCollectionError {
        .fileOperationFailed(operation: operation, code: errno)
    }
}

private extension JSONEncoder {
    static var interactionTrace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
