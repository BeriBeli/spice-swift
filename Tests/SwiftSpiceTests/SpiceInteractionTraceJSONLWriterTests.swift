import Darwin
import Foundation
import Synchronization
import Testing
@testable import SwiftSpice

@Suite("Interaction trace JSONL writer")
struct SpiceInteractionTraceJSONLWriterTests {
    @Test func canonicalSchemaTwoLineIsExactlyIdempotent() throws {
        try withTemporaryTraceDirectory { directory in
            let output = directory.appending(path: "input-events.jsonl")
            let record = WriterFixture.record(runID: "run-1")
            let first = SpiceInteractionTraceJSONLWriter(outputURL: output)
            let second = SpiceInteractionTraceJSONLWriter(outputURL: output)

            try first.append(record)
            let original = try Data(contentsOf: output)
            try second.append(record)

            #expect(try Data(contentsOf: output) == original)
            #expect(original == WriterFixture.line(record))
            #expect(original.last == 0x0A)
            #expect(String(decoding: original, as: UTF8.self).hasPrefix(
                "{\"action_class\":\"click\",\"delivery_sequence\":"
            ))
            let decoded = try JSONDecoder().decode(
                SpiceInteractionTraceRecord.self,
                from: original.dropLast()
            )
            #expect(decoded == record)
            #expect(decoded.schemaVersion == 2)
        }
    }

    @Test func firstAppendRejectsAReservedEvidenceFailureBeforeItCanPoisonTheFile() throws {
        try withTemporaryTraceDirectory { directory in
            let output = directory.appending(path: "input-events.jsonl")
            let writer = SpiceInteractionTraceJSONLWriter(outputURL: output)
            let reserved = WriterFixture.record(invalidReason: "missing_presented")
            let encoded = WriterFixture.line(reserved).dropLast()

            #expect(!reserved.valid)
            #expect(reserved.invalidReason == "missing_presented")
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    SpiceInteractionTraceRecord.self,
                    from: encoded
                )
            }
            #expect(throws: SpiceInteractionTraceCollectionError.invalidRecord) {
                try writer.append(reserved)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))

            let valid = WriterFixture.record(runID: "valid-after-rejection")
            try writer.append(valid)
            #expect(try WriterFixture.decodeLines(at: output) == [valid])
        }
    }

    @Test func pathAndExistingFileValidationFailsClosedWithoutMutation() throws {
        try withTemporaryTraceDirectory { directory in
            let record = WriterFixture.record()
            let missingParent = directory
                .appending(path: "missing", directoryHint: .isDirectory)
                .appending(path: "events.jsonl")
            #expect(throws: (any Error).self) {
                try SpiceInteractionTraceJSONLWriter(outputURL: missingParent).append(record)
            }
            #expect(!FileManager.default.fileExists(atPath: missingParent.path))

            let nonFile = try #require(URL(string: "https://example.invalid/events.jsonl"))
            #expect(throws: SpiceInteractionTraceCollectionError.invalidOutputPath) {
                try SpiceInteractionTraceJSONLWriter(outputURL: nonFile).append(record)
            }

            let realParent = directory.appending(path: "real", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
            let parentLink = directory.appending(path: "parent-link")
            try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: realParent)
            #expect(throws: SpiceInteractionTraceCollectionError.outputIsSymbolicLink) {
                try SpiceInteractionTraceJSONLWriter(
                    outputURL: parentLink.appending(path: "events.jsonl")
                ).append(record)
            }

            let nested = realParent.appending(path: "nested", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let intermediateLink = directory.appending(path: "intermediate-link")
            try FileManager.default.createSymbolicLink(at: intermediateLink, withDestinationURL: realParent)
            #expect(throws: SpiceInteractionTraceCollectionError.outputIsSymbolicLink) {
                try SpiceInteractionTraceJSONLWriter(
                    outputURL: intermediateLink
                        .appending(path: "nested", directoryHint: .isDirectory)
                        .appending(path: "events.jsonl")
                ).append(record)
            }

            let target = directory.appending(path: "target.jsonl")
            try Data().write(to: target)
            let outputLink = directory.appending(path: "output-link.jsonl")
            try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: target)
            #expect(throws: SpiceInteractionTraceCollectionError.outputIsSymbolicLink) {
                try SpiceInteractionTraceJSONLWriter(outputURL: outputLink).append(record)
            }

            for (name, bytes) in [
                ("malformed.jsonl", Data("{not-json}\n".utf8)),
                ("noncanonical.jsonl", Data("  \(String(decoding: WriterFixture.line(record).dropLast(), as: UTF8.self))\n".utf8)),
            ] {
                let output = directory.appending(path: name)
                try bytes.write(to: output)
                #expect(throws: SpiceInteractionTraceCollectionError.invalidExistingJSONL) {
                    try SpiceInteractionTraceJSONLWriter(outputURL: output).append(record)
                }
                #expect(try Data(contentsOf: output) == bytes)
            }
        }
    }

    @Test func recordAndFileByteLimitsAreExact() throws {
        try withTemporaryTraceDirectory { directory in
            let exactRecord = try WriterFixture.recordWithLineSize(
                SpiceInteractionTraceJSONLWriter.maximumRecordBytes,
                runID: "record-boundary"
            )
            let recordOutput = directory.appending(path: "record-boundary.jsonl")
            try SpiceInteractionTraceJSONLWriter(outputURL: recordOutput).append(exactRecord)
            #expect(try Data(contentsOf: recordOutput).count == 64 * 1_024)

            let oversized = try WriterFixture.recordWithLineSize(
                SpiceInteractionTraceJSONLWriter.maximumRecordBytes + 1,
                runID: "record-too-large"
            )
            #expect(throws: SpiceInteractionTraceCollectionError.recordTooLarge(
                actual: SpiceInteractionTraceJSONLWriter.maximumRecordBytes + 1,
                maximum: SpiceInteractionTraceJSONLWriter.maximumRecordBytes
            )) {
                try SpiceInteractionTraceJSONLWriter(
                    outputURL: directory.appending(path: "oversized.jsonl")
                ).append(oversized)
            }

            let finalRecord = WriterFixture.record(runID: "file-final")
            let finalLine = WriterFixture.line(finalRecord)
            let existingSize = SpiceInteractionTraceJSONLWriter.maximumFileBytes
                - finalLine.count
            let fileOutput = directory.appending(path: "file-boundary.jsonl")
            try WriterFixture.existingJSONL(exactByteCount: existingSize).write(to: fileOutput)
            try SpiceInteractionTraceJSONLWriter(outputURL: fileOutput).append(finalRecord)
            #expect(try Data(contentsOf: fileOutput).count == 16 * 1_024 * 1_024)

            let overflow = WriterFixture.record(runID: "file-overflow")
            #expect(throws: SpiceInteractionTraceCollectionError.outputTooLarge(
                actual: SpiceInteractionTraceJSONLWriter.maximumFileBytes
                    + WriterFixture.line(overflow).count,
                maximum: SpiceInteractionTraceJSONLWriter.maximumFileBytes
            )) {
                try SpiceInteractionTraceJSONLWriter(outputURL: fileOutput).append(overflow)
            }
            #expect(try Data(contentsOf: fileOutput).count == 16 * 1_024 * 1_024)
        }
    }

    @Test func writerPreservesCallerDirectoryPermissionsAndProtectsOwnedFiles() throws {
        try withTemporaryTraceDirectory { directory in
            let callerDirectory = directory.appending(
                path: "caller-owned",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: callerDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: callerDirectory.path
            )
            let output = callerDirectory.appending(path: "input-events.jsonl")
            try SpiceInteractionTraceJSONLWriter(outputURL: output).append(
                WriterFixture.record()
            )

            #expect(try posixPermissions(callerDirectory) == 0o755)
            #expect(try posixPermissions(output) == 0o600)
            #expect(try posixPermissions(
                callerDirectory.appending(path: ".input-events.jsonl.lock")
            ) == 0o600)
        }
    }

    @Test func independentWritersSerializeConcurrentDuplicateAndDistinctRecords() async throws {
        for round in 0..<24 {
            try await withTemporaryTraceDirectory { directory in
                let duplicateOutput = directory.appending(path: "duplicate.jsonl")
                let duplicate = WriterFixture.record(runID: "duplicate-\(round)")
                let duplicateFailures = await concurrentlyAppend([
                    (SpiceInteractionTraceJSONLWriter(outputURL: duplicateOutput), duplicate),
                    (SpiceInteractionTraceJSONLWriter(outputURL: duplicateOutput), duplicate),
                ])
                #expect(duplicateFailures.isEmpty)
                let duplicateLines = try WriterFixture.decodeLines(at: duplicateOutput)
                #expect(duplicateLines == [duplicate])

                let distinctOutput = directory.appending(path: "distinct.jsonl")
                let first = WriterFixture.record(runID: "first-\(round)")
                let second = WriterFixture.record(runID: "second-\(round)")
                let distinctFailures = await concurrentlyAppend([
                    (SpiceInteractionTraceJSONLWriter(outputURL: distinctOutput), first),
                    (SpiceInteractionTraceJSONLWriter(outputURL: distinctOutput), second),
                ])
                #expect(distinctFailures.isEmpty)
                let distinctRunIDs = Set(
                    try WriterFixture.decodeLines(at: distinctOutput).map(\.runId)
                )
                #expect(
                    distinctRunIDs == Set([first.runId, second.runId])
                )
            }
        }
    }

    @Test func failedAppendRetriesTheSameCachedCaptureRecord() throws {
        try withTemporaryTraceDirectory { directory in
            let diagnostics = SpicePresentationDiagnostics()
            let capture = try WriterFixture.capture(diagnostics: diagnostics)
            let missingOutput = directory
                .appending(path: "missing", directoryHint: .isDirectory)
                .appending(path: "events.jsonl")
            #expect(throws: (any Error).self) {
                try capture.append(
                    to: SpiceInteractionTraceJSONLWriter(outputURL: missingOutput),
                    invalidReason: "first_failure"
                )
            }

            let output = directory.appending(path: "events.jsonl")
            let retried = try capture.append(
                to: SpiceInteractionTraceJSONLWriter(outputURL: output),
                invalidReason: "must_not_replace_cached_reason"
            )
            #expect(retried.invalidReason == "first_failure")
            #expect(try WriterFixture.decodeLines(at: output) == [retried])
            #expect(throws: SpiceInteractionTraceCollectionError.captureAlreadyFinished) {
                try capture.append(to: SpiceInteractionTraceJSONLWriter(outputURL: output))
            }
        }
    }

    @Test func derivedFieldMismatchAndMaximumExistingLineAreRejectedUnchanged() throws {
        try withTemporaryTraceDirectory { directory in
            let record = WriterFixture.record()
            let canonical = String(decoding: WriterFixture.line(record), as: UTF8.self)
            let forged = Data(canonical.replacingOccurrences(
                of: "\"valid\":true",
                with: "\"valid\":false"
            ).utf8)
            let forgedOutput = directory.appending(path: "forged.jsonl")
            try forged.write(to: forgedOutput)
            #expect(throws: SpiceInteractionTraceCollectionError.invalidExistingJSONL) {
                try SpiceInteractionTraceJSONLWriter(outputURL: forgedOutput).append(record)
            }
            #expect(try Data(contentsOf: forgedOutput) == forged)

            let maximumExisting = try WriterFixture.recordWithLineSize(
                SpiceInteractionTraceJSONLWriter.maximumRecordBytes + 1,
                runID: "existing-too-large"
            )
            let maximumBytes = WriterFixture.line(maximumExisting)
            let maximumOutput = directory.appending(path: "maximum-existing.jsonl")
            try maximumBytes.write(to: maximumOutput)
            #expect(throws: SpiceInteractionTraceCollectionError.invalidExistingJSONL) {
                try SpiceInteractionTraceJSONLWriter(outputURL: maximumOutput).append(record)
            }
            #expect(try Data(contentsOf: maximumOutput) == maximumBytes)
        }
    }

    @Test func cancelledWaitAndRepeatedFinishRespectCaptureState() async throws {
        try await withTemporaryTraceDirectory { directory in
            let diagnostics = SpicePresentationDiagnostics()
            let capture = try WriterFixture.capture(diagnostics: diagnostics)
            let registered = DispatchSemaphore(value: 0)
            let waiter = Task {
                try await capture.waitForExactPresentation { registered.signal() }
            }
            #expect(await waitForWriterSemaphore(registered) == .success)
            waiter.cancel()
            await #expect(throws: CancellationError.self) { try await waiter.value }

            let record = try capture.finish(invalidReason: "cancelled_wait")
            #expect(record.invalidReason == "cancelled_wait")
            #expect(throws: SpiceInteractionTraceCollectionError.captureAlreadyFinished) {
                try capture.finish()
            }
            let output = directory.appending(path: "events.jsonl")
            #expect(try capture.append(
                to: SpiceInteractionTraceJSONLWriter(outputURL: output),
                invalidReason: "changed"
            ) == record)
            #expect(throws: SpiceInteractionTraceCollectionError.captureAlreadyFinished) {
                try capture.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 3)
            }
        }
    }
}

private enum WriterFixture {
    static func record(
        runID: String = "run-1",
        invalidReason: String? = nil
    ) -> SpiceInteractionTraceRecord {
        SpiceInteractionTraceRecord(
            pairId: "pair-click",
            version: "v0.2.7",
            runId: runID,
            order: 1,
            actionClass: .click,
            token: "0123456789abcdef",
            scheduledNs: 1,
            hostInputNs: 2,
            sendStartedNs: 3,
            sendCompletedNs: 4,
            guestReceivedNs: 1,
            guestMarkerDrawnNs: 2,
            displayReceiveNs: 5,
            surfaceReadyNs: 6,
            selectedRevisionReadyNs: 7,
            selectionNs: 8,
            metalCommitNs: 9,
            presentedNs: 10,
            displayChannelID: 0,
            surfaceID: 1,
            surfaceGeneration: 2,
            desktopGeneration: 3,
            frameRevision: 4,
            deliverySequence: 5,
            markerRevision: 6,
            markerChecksum: "9f9f5111",
            invalidReason: invalidReason
        )
    }

    static func line(_ record: SpiceInteractionTraceRecord) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try! encoder.encode(record)
        data.append(0x0A)
        return data
    }

    static func recordWithLineSize(
        _ size: Int,
        runID: String
    ) throws -> SpiceInteractionTraceRecord {
        let seed = record(runID: runID, invalidReason: "x")
        let seedSize = line(seed).count
        guard size >= seedSize else {
            throw WriterFixtureError.requestedLineTooSmall
        }
        let result = record(
            runID: runID,
            invalidReason: String(repeating: "x", count: 1 + size - seedSize)
        )
        guard line(result).count == size else {
            throw WriterFixtureError.unexpectedLineSize
        }
        return result
    }

    static func existingJSONL(exactByteCount: Int) throws -> Data {
        let maximumLineSize = SpiceInteractionTraceJSONLWriter.maximumRecordBytes
        let maximumLine = line(try recordWithLineSize(
            maximumLineSize,
            runID: "existing-fill"
        ))
        let minimumLineSize = line(record(runID: "existing-tail", invalidReason: "x")).count
        var data = Data()
        while exactByteCount - data.count > maximumLineSize {
            data.append(maximumLine)
        }
        var remainder = exactByteCount - data.count
        if remainder < minimumLineSize {
            data.removeLast(maximumLineSize)
            remainder += maximumLineSize
        }
        data.append(line(try recordWithLineSize(
            remainder,
            runID: "existing-tail"
        )))
        guard data.count == exactByteCount else {
            throw WriterFixtureError.unexpectedLineSize
        }
        return data
    }

    static func decodeLines(at output: URL) throws -> [SpiceInteractionTraceRecord] {
        try Data(contentsOf: output)
            .split(separator: 0x0A)
            .map { try JSONDecoder().decode(SpiceInteractionTraceRecord.self, from: $0) }
    }

    static func capture(
        diagnostics: SpicePresentationDiagnostics
    ) throws -> SpiceInteractionTraceCapture {
        try SpiceInteractionTraceCapture(
            presentationDiagnostics: diagnostics,
            pairId: "pair-click",
            version: "v0.2.7",
            runId: "run-capture",
            order: 1,
            actionClass: .click,
            token: "0123456789abcdef",
            checksum: 0x9f9f_5111
        )
    }
}

private enum WriterFixtureError: Error {
    case requestedLineTooSmall
    case unexpectedLineSize
}

private func concurrentlyAppend(
    _ operations: [(SpiceInteractionTraceJSONLWriter, SpiceInteractionTraceRecord)]
) async -> [SpiceInteractionTraceCollectionError] {
    let start = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let failures = Mutex<[SpiceInteractionTraceCollectionError]>([])
    for (writer, record) in operations {
        group.enter()
        DispatchQueue.global().async {
            start.wait()
            do {
                try writer.append(record)
            } catch let error as SpiceInteractionTraceCollectionError {
                failures.withLock { $0.append(error) }
            } catch {
                failures.withLock {
                    $0.append(.fileOperationFailed(operation: "unexpected", code: -1))
                }
            }
            group.leave()
        }
    }
    for _ in operations { start.signal() }
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            group.wait()
            continuation.resume()
        }
    }
    return failures.withLock { $0 }
}

private func withTemporaryTraceDirectory<Result>(
    _ operation: (URL) throws -> Result
) throws -> Result {
    let directory = writerTemporaryRoot.appending(
        path: "interaction-writer-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try operation(directory)
}

private func withTemporaryTraceDirectory<Result: Sendable>(
    _ operation: (URL) async throws -> Result
) async throws -> Result {
    let directory = writerTemporaryRoot.appending(
        path: "interaction-writer-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await operation(directory)
}

private let writerTemporaryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()

private func posixPermissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private func waitForWriterSemaphore(
    _ semaphore: DispatchSemaphore
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 1))
        }
    }
}
