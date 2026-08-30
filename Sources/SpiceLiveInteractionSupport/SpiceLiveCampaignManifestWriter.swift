import Darwin
import Foundation
import Synchronization

package enum SpiceLiveCampaignManifestError: Error, Sendable, Equatable {
    case invalidMetadata
    case invalidManifest
    case invalidTransition
    case recorderTerminal
    case outputDirectoryUnavailable
    case outputIsSymbolicLink
    case outputIsNotRegular
    case outputTooLarge(actual: Int, maximum: Int)
    case fileOperationFailed(operation: String, code: Int32)
}

private let campaignManifestProcessLock = Mutex<Void>(())

package final class SpiceLiveCampaignManifestWriter: Sendable {
    package static let defaultMaximumBytes = 1024 * 1024
    private static let absoluteMaximumBytes = 16 * 1024 * 1024

    private let directoryPath: String
    private let outputName: String
    private let maximumBytes: Int

    package init(
        outputURL: URL,
        maximumBytes: Int = SpiceLiveCampaignManifestWriter.defaultMaximumBytes
    ) throws {
        let path = outputURL.path
        guard outputURL.isFileURL,
              path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              maximumBytes > 0,
              maximumBytes <= Self.absoluteMaximumBytes,
              !outputURL.lastPathComponent.isEmpty else {
            throw SpiceLiveCampaignManifestError.outputDirectoryUnavailable
        }

        let parent = outputURL.deletingLastPathComponent()
        var parentStatus = stat()
        guard lstat(parent.path, &parentStatus) == 0 else {
            throw SpiceLiveCampaignManifestError.outputDirectoryUnavailable
        }
        guard parentStatus.st_mode & S_IFMT != S_IFLNK else {
            throw SpiceLiveCampaignManifestError.outputIsSymbolicLink
        }
        guard parentStatus.st_mode & S_IFMT == S_IFDIR else {
            throw SpiceLiveCampaignManifestError.outputDirectoryUnavailable
        }

        let canonicalParent = Self.canonicalDirectoryPath(parent.path)
        directoryPath = canonicalParent
        outputName = outputURL.lastPathComponent
        self.maximumBytes = maximumBytes

        let descriptor = try Self.openDirectory(path: canonicalParent)
        defer { Darwin.close(descriptor) }
        try Self.validatePrivateDirectory(descriptor)
        try Self.validateExistingOutput(
            directoryDescriptor: descriptor,
            outputName: outputName,
            maximumBytes: maximumBytes
        )
    }

    package func load() throws -> SpiceLiveCampaignManifest? {
        try withTransaction { directoryDescriptor in
            try readManifest(directoryDescriptor: directoryDescriptor)?.manifest
        }
    }

    package func create(_ manifest: SpiceLiveCampaignManifest) throws {
        let encoded = try Self.encodedAndValidated(manifest, maximumBytes: maximumBytes)
        guard manifest.generation == 0,
              manifest.state == .recording,
              manifest.stages.isEmpty else {
            throw SpiceLiveCampaignManifestError.invalidTransition
        }
        try withTransaction { directoryDescriptor in
            guard case nil = try readManifest(
                directoryDescriptor: directoryDescriptor
            ) else {
                throw SpiceLiveCampaignManifestError.invalidTransition
            }
            try replace(encoded, directoryDescriptor: directoryDescriptor)
        }
    }

    package func persist(_ manifest: SpiceLiveCampaignManifest) throws {
        let encoded = try Self.encodedAndValidated(manifest, maximumBytes: maximumBytes)

        try withTransaction { directoryDescriptor in
            let existing = try readManifest(directoryDescriptor: directoryDescriptor)
            if existing?.data == encoded {
                guard fsync(directoryDescriptor) == 0 else {
                    throw operationError("fsync_directory")
                }
                return
            }
            guard let existing else {
                throw SpiceLiveCampaignManifestError.invalidTransition
            }
            let (nextGeneration, overflow) = existing.manifest.generation
                .addingReportingOverflow(1)
            guard !overflow,
                  manifest.generation == nextGeneration,
                  Self.isValidSuccessor(manifest, of: existing.manifest) else {
                throw SpiceLiveCampaignManifestError.invalidTransition
            }
            try replace(encoded, directoryDescriptor: directoryDescriptor)
        }
    }

    private func withTransaction<Result>(
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        try campaignManifestProcessLock.withLock { _ in
            let directoryDescriptor = try Self.openDirectory(path: directoryPath)
            defer { Darwin.close(directoryDescriptor) }
            try Self.validatePrivateDirectory(directoryDescriptor)

            let lockName = ".\(outputName).lock"
            let lockDescriptor = lockName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            guard lockDescriptor >= 0 else {
                if errno == ELOOP {
                    throw SpiceLiveCampaignManifestError.outputIsSymbolicLink
                }
                throw operationError("open_lock")
            }
            defer { Darwin.close(lockDescriptor) }
            var lockStatus = stat()
            guard fstat(lockDescriptor, &lockStatus) == 0 else {
                throw operationError("inspect_lock")
            }
            guard lockStatus.st_mode & S_IFMT == S_IFREG else {
                throw SpiceLiveCampaignManifestError.outputIsNotRegular
            }
            guard fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw operationError("chmod_lock")
            }
            try lock(lockDescriptor)
            defer { unlock(lockDescriptor) }
            return try body(directoryDescriptor)
        }
    }

    private func readManifest(
        directoryDescriptor: Int32
    ) throws -> (manifest: SpiceLiveCampaignManifest, data: Data)? {
        let descriptor = outputName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw SpiceLiveCampaignManifestError.outputIsSymbolicLink
            }
            throw operationError("open_output")
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw operationError("inspect_output")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SpiceLiveCampaignManifestError.outputIsNotRegular
        }
        guard status.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        guard status.st_size >= 0,
              UInt64(status.st_size) <= UInt64(maximumBytes) else {
            throw SpiceLiveCampaignManifestError.outputTooLarge(
                actual: status.st_size > Int.max ? Int.max : Int(status.st_size),
                maximum: maximumBytes
            )
        }
        let data = try readAll(from: descriptor, count: Int(status.st_size))
        guard !data.isEmpty, data.last != 0x0a else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        let manifest: SpiceLiveCampaignManifest
        do {
            manifest = try JSONDecoder().decode(SpiceLiveCampaignManifest.self, from: data)
        } catch {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        guard try Self.canonicalData(manifest) == data else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        try Self.validateShape(manifest)
        return (manifest, data)
    }

    private func replace(_ data: Data, directoryDescriptor: Int32) throws {
        let temporaryName = ".\(outputName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw operationError("open_temporary") }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw operationError("chmod_temporary")
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw operationError("fsync_temporary") }
        let renameResult = temporaryName.withCString { temporaryPointer in
            outputName.withCString { outputPointer in
                Darwin.renameat(
                    directoryDescriptor,
                    temporaryPointer,
                    directoryDescriptor,
                    outputPointer
                )
            }
        }
        guard renameResult == 0 else { throw operationError("replace_output") }
        removeTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw operationError("fsync_directory")
        }
    }

    private func readAll(from descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count + 1)
        let readCount = try data.withUnsafeMutableBytes { bytes -> Int in
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
        guard readCount == count else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        data.removeSubrange(count..<data.count)
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

    private static func canonicalData(
        _ manifest: SpiceLiveCampaignManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private static func encodedAndValidated(
        _ manifest: SpiceLiveCampaignManifest,
        maximumBytes: Int
    ) throws -> Data {
        let encoded = try canonicalData(manifest)
        guard encoded.count <= maximumBytes else {
            throw SpiceLiveCampaignManifestError.outputTooLarge(
                actual: encoded.count,
                maximum: maximumBytes
            )
        }
        try validateShape(manifest)
        return encoded
    }

    private static func validateShape(_ manifest: SpiceLiveCampaignManifest) throws {
        guard manifest.schemaVersion == SpiceLiveCampaignManifest.currentSchemaVersion,
              manifest.planDigest.utf8.count == 64,
              manifest.planDigest.utf8.allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
              }),
              manifest.runs.count == 20,
              manifest.stages.count <= 260,
              Set(manifest.runs.map(\.logicalRunID)).count == manifest.runs.count,
              Set(manifest.runs.compactMap(\.evidenceRunID)).count
                  == manifest.runs.compactMap(\.evidenceRunID).count else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
    }

    private static func isValidSuccessor(
        _ candidate: SpiceLiveCampaignManifest,
        of existing: SpiceLiveCampaignManifest
    ) -> Bool {
        guard candidate.hasSameImmutableIdentity(as: existing),
              existing.state == .recording,
              candidate.stages.count == existing.stages.count
                  || candidate.stages.count == existing.stages.count + 1,
              candidate.stages.starts(with: existing.stages),
              candidate.runs.count == existing.runs.count else {
            return false
        }
        var newEvidenceBindings = 0
        for (oldRun, newRun) in zip(existing.runs, candidate.runs) {
            switch (oldRun.evidenceRunID, newRun.evidenceRunID) {
            case (nil, nil):
                break
            case let (nil, .some(newID)):
                newEvidenceBindings += 1
                guard candidate.stages.count == existing.stages.count + 1,
                      candidate.stages.last?.stage == .fixtureStart,
                      candidate.stages.last?.outcome == .succeeded,
                      candidate.stages.last?.runID == newRun.logicalRunID,
                      !existing.runs.contains(where: { $0.evidenceRunID == newID }) else {
                    return false
                }
            case let (.some(oldID), .some(newID)):
                guard oldID == newID else { return false }
            case (.some, nil):
                return false
            }
        }
        guard newEvidenceBindings <= 1 else { return false }

        switch candidate.state {
        case .recording:
            return candidate.stages.count == existing.stages.count + 1
                && candidate.stages.last?.outcome == .succeeded
        case .failed:
            return candidate.stages == existing.stages
                || (candidate.stages.count == existing.stages.count + 1
                    && candidate.stages.last?.outcome == .failed)
        case .interrupted:
            return candidate.stages == existing.stages
        case .finalized:
            return candidate.stages == existing.stages
                && candidate.stages.count == 260
                && candidate.stages.allSatisfy { $0.outcome == .succeeded }
        }
    }

    private static func validateExistingOutput(
        directoryDescriptor: Int32,
        outputName: String,
        maximumBytes: Int
    ) throws {
        var status = stat()
        let result = outputName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            guard errno == ENOENT else { throw operationError("inspect_output") }
            return
        }
        if status.st_mode & S_IFMT == S_IFLNK {
            throw SpiceLiveCampaignManifestError.outputIsSymbolicLink
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SpiceLiveCampaignManifestError.outputIsNotRegular
        }
        guard status.st_size >= 0,
              UInt64(status.st_size) <= UInt64(maximumBytes) else {
            throw SpiceLiveCampaignManifestError.outputTooLarge(
                actual: status.st_size > Int.max ? Int.max : Int(status.st_size),
                maximum: maximumBytes
            )
        }
    }

    private static func validatePrivateDirectory(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw operationError("inspect_directory")
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else {
            throw SpiceLiveCampaignManifestError.outputDirectoryUnavailable
        }
    }

    private static func openDirectory(path: String) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw operationError("open_root") }
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            let next = String(component).withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            if next < 0 {
                let code = errno
                Darwin.close(descriptor)
                if code == ELOOP { throw SpiceLiveCampaignManifestError.outputIsSymbolicLink }
                throw SpiceLiveCampaignManifestError.fileOperationFailed(
                    operation: "open_directory",
                    code: code
                )
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func canonicalDirectoryPath(_ path: String) -> String {
        // Darwin exposes these two root aliases as stable compatibility
        // symlinks. Normalize only those aliases; every remaining component
        // is opened with O_NOFOLLOW rather than resolved by pathname.
        if path == "/var" || path.hasPrefix("/var/") {
            return "/private\(path)"
        }
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            return path == "/tmp" ? "/private/tmp" : "/private\(path)"
        }
        return path
    }

    private static func operationError(
        _ operation: String
    ) -> SpiceLiveCampaignManifestError {
        .fileOperationFailed(operation: operation, code: errno)
    }

    private func operationError(_ operation: String) -> SpiceLiveCampaignManifestError {
        Self.operationError(operation)
    }
}
