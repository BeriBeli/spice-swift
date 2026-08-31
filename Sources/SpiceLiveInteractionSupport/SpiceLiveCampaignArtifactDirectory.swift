import CryptoKit
import Darwin
import Foundation
import Synchronization
import SwiftSpice

package enum SpiceLiveCampaignArtifactError: Error, Sendable, Equatable {
    case invalidInput
    case terminal
    case outputExists
    case unsafePath
    case ioFailure(operation: String, code: Int32)
}

package struct SpiceLiveCampaignArtifactReference: Codable, Sendable, Equatable {
    package let relativePath: String
    package let sha256: String
    package let byteCount: UInt64

    fileprivate init(relativePath: String, data: Data) {
        self.relativePath = relativePath
        sha256 = SpiceLiveCampaignArtifactDirectory.digest(data)
        byteCount = UInt64(data.count)
    }

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case sha256
        case byteCount = "byte_count"
    }
}

package struct SpiceLiveCampaignArtifactQuantiles: Codable, Sendable, Equatable {
    package let p50: Double
    package let p95: Double

    fileprivate init(_ quantiles: SpiceLiveQuantiles) {
        p50 = quantiles.p50Nanoseconds
        p95 = quantiles.p95Nanoseconds
    }
}

package struct SpiceLiveCampaignArtifactActionReport: Codable, Sendable, Equatable {
    package let pairCount: Int
    package let baselineInputToPresented: SpiceLiveCampaignArtifactQuantiles
    package let candidateInputToPresented: SpiceLiveCampaignArtifactQuantiles
    package let pairedInputToPresentedDelta: SpiceLiveCampaignArtifactQuantiles

    fileprivate init(_ summary: SpicePairedInteractionActionSummary) {
        pairCount = summary.pairs.count
        baselineInputToPresented = .init(summary.baselineInputToPresented)
        candidateInputToPresented = .init(summary.candidateInputToPresented)
        pairedInputToPresentedDelta = .init(summary.pairedInputToPresentedDelta)
    }

    enum CodingKeys: String, CodingKey {
        case pairCount = "pair_count"
        case baselineInputToPresented = "baseline_input_to_presented"
        case candidateInputToPresented = "candidate_input_to_presented"
        case pairedInputToPresentedDelta = "paired_input_to_presented_delta"
    }
}

package struct SpiceLiveCampaignArtifactResourceReport: Codable, Sendable, Equatable {
    package let pairCount: Int
    package let baselineCPUPercent: SpiceLiveCampaignArtifactQuantiles
    package let candidateCPUPercent: SpiceLiveCampaignArtifactQuantiles
    package let pairedCPUPercentDelta: SpiceLiveCampaignArtifactQuantiles
    package let baselinePeakRSSBytes: SpiceLiveCampaignArtifactQuantiles
    package let candidatePeakRSSBytes: SpiceLiveCampaignArtifactQuantiles
    package let pairedPeakRSSBytesDelta: SpiceLiveCampaignArtifactQuantiles

    fileprivate init(_ guardrails: SpicePairedInteractionResourceGuardrails) {
        pairCount = guardrails.pairs.count
        baselineCPUPercent = .init(guardrails.baselineCPUPercent)
        candidateCPUPercent = .init(guardrails.candidateCPUPercent)
        pairedCPUPercentDelta = .init(guardrails.pairedCPUPercentDelta)
        baselinePeakRSSBytes = .init(guardrails.baselinePeakRSSBytes)
        candidatePeakRSSBytes = .init(guardrails.candidatePeakRSSBytes)
        pairedPeakRSSBytesDelta = .init(guardrails.pairedPeakRSSBytesDelta)
    }

    enum CodingKeys: String, CodingKey {
        case pairCount = "pair_count"
        case baselineCPUPercent = "baseline_cpu_percent"
        case candidateCPUPercent = "candidate_cpu_percent"
        case pairedCPUPercentDelta = "paired_cpu_percent_delta"
        case baselinePeakRSSBytes = "baseline_peak_rss_bytes"
        case candidatePeakRSSBytes = "candidate_peak_rss_bytes"
        case pairedPeakRSSBytesDelta = "paired_peak_rss_bytes_delta"
    }
}

package struct SpiceLiveCampaignArtifactReportSnapshot: Codable, Sendable, Equatable {
    package let schemaVersion: UInt64
    package let recordCount: Int
    package let runCount: Int
    package let click: SpiceLiveCampaignArtifactActionReport
    package let key: SpiceLiveCampaignArtifactActionReport
    package let motion: SpiceLiveCampaignArtifactActionReport
    package let resources: SpiceLiveCampaignArtifactResourceReport

    fileprivate init(_ report: SpicePairedInteractionArtifactReport) {
        schemaVersion = 1
        recordCount = report.recordCount
        runCount = report.runCount
        click = .init(report.summary(for: .click))
        key = .init(report.summary(for: .key))
        motion = .init(report.summary(for: .motion))
        resources = .init(report.resourceGuardrails)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordCount = "record_count"
        case runCount = "run_count"
        case click
        case key
        case motion
        case resources
    }
}

package struct SpiceLiveCampaignArtifactIndex: Codable, Sendable, Equatable {
    package let schemaVersion: UInt64
    package let campaignID: String
    package let planDigest: String
    package let executionContractDigest: String
    package let recordCount: Int
    package let runCount: Int
    package let runArtifacts: [SpiceLiveCampaignArtifactReference]
    package let terminalManifest: SpiceLiveCampaignArtifactReference
    package let report: SpiceLiveCampaignArtifactReference

    fileprivate init(
        manifest: SpiceLiveCampaignManifest,
        report: SpiceLiveCampaignArtifactReportSnapshot,
        runArtifacts: [SpiceLiveCampaignArtifactReference],
        terminalManifest: SpiceLiveCampaignArtifactReference,
        reportReference: SpiceLiveCampaignArtifactReference
    ) throws {
        guard let executionContractDigest = manifest.executionContractDigest else {
            throw SpiceLiveCampaignArtifactError.invalidInput
        }
        schemaVersion = 1
        campaignID = manifest.campaignID
        planDigest = manifest.planDigest
        self.executionContractDigest = executionContractDigest
        recordCount = report.recordCount
        runCount = report.runCount
        self.runArtifacts = runArtifacts
        self.terminalManifest = terminalManifest
        self.report = reportReference
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case campaignID = "campaign_id"
        case planDigest = "plan_digest"
        case executionContractDigest = "execution_contract_digest"
        case recordCount = "record_count"
        case runCount = "run_count"
        case runArtifacts = "run_artifacts"
        case terminalManifest = "terminal_manifest"
        case report
    }
}

private struct SpiceLiveCampaignRunArtifact: Codable, Sendable {
    let schemaVersion: UInt64
    let logicalRunID: String
    let evidenceRunID: String
    let resourceSample: ResourceSample
    let teardownResult: TeardownResult
    let records: SpiceLiveCampaignArtifactReference

    struct ResourceSample: Codable, Sendable {
        let runID: String
        let cpuPercent: Double
        let peakRSSBytes: UInt64

        enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case cpuPercent = "cpu_percent"
            case peakRSSBytes = "peak_rss_bytes"
        }
    }

    struct TeardownResult: Codable, Sendable {
        let status: Int32
        let userNanoseconds: UInt64
        let systemNanoseconds: UInt64
        let peakResidentBytes: UInt64

        enum CodingKeys: String, CodingKey {
            case status
            case userNanoseconds = "user_nanoseconds"
            case systemNanoseconds = "system_nanoseconds"
            case peakResidentBytes = "peak_resident_bytes"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case logicalRunID = "logical_run_id"
        case evidenceRunID = "evidence_run_id"
        case resourceSample = "resource_sample"
        case teardownResult = "teardown_result"
        case records
    }
}

package final class SpiceLiveCampaignArtifactDirectory: Sendable {
    private enum Phase: Sendable {
        case collecting
        case terminal
    }

    private struct Storage: Sendable {
        var phase: Phase = .collecting
        var accumulator: SpiceLiveCampaignArtifactAccumulator
        var runArtifacts: [SpiceLiveCampaignArtifactReference] = []
    }

    private static let manifestName = "campaign-manifest.json"
    private static let reportName = "report.json"
    private static let indexName = "success-index.json"
    private static let maximumObjectBytes = 1024 * 1024

    private let plan: SpiceLiveCampaignPlan
    private let pointerMode: SpicePointerMode
    private let directoryPath: String
    private let directoryDescriptor: Int32
    private let storage: Mutex<Storage>

    package let manifestWriter: SpiceLiveCampaignManifestWriter
    package let indexURL: URL

    package init(
        directoryURL: URL,
        plan: SpiceLiveCampaignPlan,
        pointerMode: SpicePointerMode
    ) throws {
        let descriptor = try Self.createDirectory(at: directoryURL)
        do {
            manifestWriter = try SpiceLiveCampaignManifestWriter(
                duplicatingDirectoryDescriptor: descriptor,
                outputName: Self.manifestName
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        self.plan = plan
        self.pointerMode = pointerMode
        directoryPath = Self.canonicalDirectoryPath(directoryURL.path)
        directoryDescriptor = descriptor
        indexURL = directoryURL.appending(path: Self.indexName)
        let accumulator = SpiceLiveCampaignArtifactAccumulator(
            plan: plan,
            pointerMode: pointerMode
        )
        storage = Mutex(Storage(accumulator: accumulator))
    }

    deinit {
        Darwin.close(directoryDescriptor)
    }

    package func recordRun(
        logicalRunID: String,
        evidenceRunID: SpiceLiveEvidenceRunID,
        canonicalRecords: [Data],
        resourceSample: SpicePairedInteractionResourceSample,
        teardownResult: SpiceLiveProcessGroup.TerminalResult
    ) throws {
        try storage.withLock { storage in
            guard case .collecting = storage.phase else {
                throw SpiceLiveCampaignArtifactError.terminal
            }
            do {
                guard teardownResult.status == 0,
                      resourceSample.runId == evidenceRunID.rawValue,
                      resourceSample.peakRSSBytes
                        == teardownResult.resourceUsage.peakResidentBytes,
                      storage.runArtifacts.count < plan.runs.count else {
                    throw SpiceLiveCampaignArtifactError.invalidInput
                }

                var candidate = storage.accumulator
                try candidate.recordRun(
                    logicalRunID: logicalRunID,
                    evidenceRunID: evidenceRunID,
                    canonicalRecords: canonicalRecords
                )
                try candidate.recordResourceSample(
                    logicalRunID: logicalRunID,
                    sample: resourceSample
                )

                let runIndex = storage.runArtifacts.count
                let recordsName = String(
                    format: "run-%02d.records.jsonl",
                    runIndex
                )
                let recordsData = canonicalRecords.reduce(into: Data()) {
                    $0.append($1)
                }
                let recordsReference = try publish(
                    recordsData,
                    named: recordsName
                )

                let envelope = SpiceLiveCampaignRunArtifact(
                    schemaVersion: 1,
                    logicalRunID: logicalRunID,
                    evidenceRunID: evidenceRunID.rawValue,
                    resourceSample: .init(
                        runID: resourceSample.runId,
                        cpuPercent: resourceSample.cpuPercent,
                        peakRSSBytes: resourceSample.peakRSSBytes
                    ),
                    teardownResult: .init(
                        status: teardownResult.status,
                        userNanoseconds: teardownResult.resourceUsage.userNanoseconds,
                        systemNanoseconds: teardownResult.resourceUsage.systemNanoseconds,
                        peakResidentBytes:
                            teardownResult.resourceUsage.peakResidentBytes
                    ),
                    records: recordsReference
                )
                let envelopeName = String(format: "run-%02d.json", runIndex)
                let envelopeReference = try publish(
                    Self.canonicalData(envelope),
                    named: envelopeName
                )

                storage.accumulator = candidate
                storage.runArtifacts.append(envelopeReference)
            } catch {
                storage.phase = .terminal
                throw error
            }
        }
    }

    package func publishSuccess() throws -> SpiceLiveCampaignArtifactIndex {
        try storage.withLock { storage in
            guard case .collecting = storage.phase else {
                throw SpiceLiveCampaignArtifactError.terminal
            }
            do {
                try validateDirectoryIdentity()
                guard storage.runArtifacts.count == plan.runs.count,
                      let manifest = try manifestWriter.load(),
                      manifest.state == .finalized,
                      manifest.generation == 261,
                      let contract = manifest.executionContract,
                      contract.pointerMode == pointerMode else {
                    throw SpiceLiveCampaignArtifactError.invalidInput
                }
                let execution = try SpiceLiveCampaignManifestValidator
                    .validateAndReplay(manifest: manifest, plan: plan)
                for run in plan.runs {
                    guard let evidenceRunID = storage.accumulator.evidenceRunID(
                        forLogicalRunID: run.runID
                    ),
                    manifest.runs.contains(where: {
                        $0.logicalRunID == run.runID
                            && $0.evidenceRunID == evidenceRunID
                    }) else {
                        throw SpiceLiveCampaignArtifactError.invalidInput
                    }
                }
                try validatePublishedRunArtifacts(storage)

                var candidate = storage.accumulator
                let evaluated = try candidate.evaluate(execution: execution)
                let report = SpiceLiveCampaignArtifactReportSnapshot(evaluated)

                let manifestData = try readExisting(named: Self.manifestName)
                guard manifestData == (try Self.canonicalData(manifest)) else {
                    throw SpiceLiveCampaignArtifactError.invalidInput
                }
                let manifestReference = SpiceLiveCampaignArtifactReference(
                    relativePath: Self.manifestName,
                    data: manifestData
                )
                let reportReference = try publish(
                    Self.canonicalData(report),
                    named: Self.reportName
                )
                let index = try SpiceLiveCampaignArtifactIndex(
                    manifest: manifest,
                    report: report,
                    runArtifacts: storage.runArtifacts,
                    terminalManifest: manifestReference,
                    reportReference: reportReference
                )
                _ = try publish(
                    Self.canonicalData(index),
                    named: Self.indexName
                )
                storage.accumulator = candidate
                storage.phase = .terminal
                return index
            } catch {
                storage.phase = .terminal
                throw error
            }
        }
    }

    private func validatePublishedRunArtifacts(_ storage: Storage) throws {
        for (runIndex, run) in plan.runs.enumerated() {
            let envelopeName = String(format: "run-%02d.json", runIndex)
            let recordsName = String(format: "run-%02d.records.jsonl", runIndex)
            let envelopeData = try readExisting(named: envelopeName)
            let envelopeReference = SpiceLiveCampaignArtifactReference(
                relativePath: envelopeName,
                data: envelopeData
            )
            guard envelopeReference == storage.runArtifacts[runIndex] else {
                throw SpiceLiveCampaignArtifactError.invalidInput
            }

            let envelope: SpiceLiveCampaignRunArtifact
            do {
                envelope = try JSONDecoder().decode(
                    SpiceLiveCampaignRunArtifact.self,
                    from: envelopeData
                )
            } catch {
                throw SpiceLiveCampaignArtifactError.invalidInput
            }
            guard try Self.canonicalData(envelope) == envelopeData,
                  envelope.schemaVersion == 1,
                  envelope.logicalRunID == run.runID,
                  let evidenceRunID = storage.accumulator.evidenceRunID(
                    forLogicalRunID: run.runID
                  ),
                  envelope.evidenceRunID == evidenceRunID.rawValue,
                  envelope.resourceSample.runID == evidenceRunID.rawValue,
                  envelope.resourceSample.cpuPercent.isFinite,
                  envelope.resourceSample.cpuPercent >= 0,
                  envelope.resourceSample.peakRSSBytes
                    == envelope.teardownResult.peakResidentBytes,
                  envelope.teardownResult.status == 0,
                  envelope.records.relativePath == recordsName else {
                throw SpiceLiveCampaignArtifactError.invalidInput
            }

            let recordsData = try readExisting(named: recordsName)
            guard SpiceLiveCampaignArtifactReference(
                relativePath: recordsName,
                data: recordsData
            ) == envelope.records else {
                throw SpiceLiveCampaignArtifactError.invalidInput
            }
        }
    }

    private func validateDirectoryIdentity() throws {
        let currentDescriptor = try Self.openDirectory(atCanonicalPath: directoryPath)
        defer { Darwin.close(currentDescriptor) }
        var ownedStatus = stat()
        var currentStatus = stat()
        guard fstat(directoryDescriptor, &ownedStatus) == 0,
              fstat(currentDescriptor, &currentStatus) == 0 else {
            throw Self.operationError("inspect_directory_identity")
        }
        guard ownedStatus.st_dev == currentStatus.st_dev,
              ownedStatus.st_ino == currentStatus.st_ino else {
            throw SpiceLiveCampaignArtifactError.unsafePath
        }
    }

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func publish(
        _ data: Data,
        named name: String
    ) throws -> SpiceLiveCampaignArtifactReference {
        guard !data.isEmpty, data.count <= Self.maximumObjectBytes else {
            throw SpiceLiveCampaignArtifactError.invalidInput
        }
        try ensureMissing(name)

        let temporaryName = ".artifact.tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw Self.operationError("open_temporary") }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                temporaryName.withCString {
                    _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw Self.operationError("chmod_temporary")
        }
        try Self.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw Self.operationError("fsync_temporary")
        }
        let result = temporaryName.withCString { temporaryPointer in
            name.withCString { outputPointer in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    temporaryPointer,
                    directoryDescriptor,
                    outputPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw SpiceLiveCampaignArtifactError.outputExists
            }
            throw Self.operationError("publish_output")
        }
        removeTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw Self.operationError("fsync_directory")
        }
        return SpiceLiveCampaignArtifactReference(relativePath: name, data: data)
    }

    private func ensureMissing(_ name: String) throws {
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            throw SpiceLiveCampaignArtifactError.outputExists
        }
        guard errno == ENOENT else {
            throw Self.operationError("inspect_output")
        }
    }

    private func readExisting(named name: String) throws -> Data {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw Self.operationError("open_output") }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw Self.operationError("inspect_output")
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o777 == S_IRUSR | S_IWUSR,
              status.st_size > 0,
              UInt64(status.st_size) <= UInt64(Self.maximumObjectBytes) else {
            throw SpiceLiveCampaignArtifactError.invalidInput
        }
        return try Self.readAll(from: descriptor, count: Int(status.st_size))
    }

    private static func createDirectory(at directoryURL: URL) throws -> Int32 {
        let path = directoryURL.path
        guard directoryURL.isFileURL,
              path.hasPrefix("/"),
              path != "/",
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw SpiceLiveCampaignArtifactError.unsafePath
        }
        let canonicalPath = canonicalDirectoryPath(path)
        let components = canonicalPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard let name = components.last else {
            throw SpiceLiveCampaignArtifactError.unsafePath
        }

        var parentDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw operationError("open_root") }
        for component in components.dropLast() {
            let next = String(component).withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            if next < 0 {
                let code = errno
                Darwin.close(parentDescriptor)
                if code == ELOOP || code == ENOTDIR {
                    throw SpiceLiveCampaignArtifactError.unsafePath
                }
                throw SpiceLiveCampaignArtifactError.ioFailure(
                    operation: "open_parent",
                    code: code
                )
            }
            Darwin.close(parentDescriptor)
            parentDescriptor = next
        }
        defer { Darwin.close(parentDescriptor) }

        let mkdirResult = String(name).withCString {
            Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        guard mkdirResult == 0 else {
            if errno == EEXIST {
                throw SpiceLiveCampaignArtifactError.outputExists
            }
            throw operationError("create_directory")
        }
        let descriptor = String(name).withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw operationError("open_directory") }
        do {
            guard fchmod(descriptor, S_IRWXU) == 0 else {
                throw operationError("chmod_directory")
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o777 == S_IRWXU else {
                throw SpiceLiveCampaignArtifactError.unsafePath
            }
            guard fsync(descriptor) == 0 else {
                throw operationError("fsync_directory")
            }
            guard fsync(parentDescriptor) == 0 else {
                throw operationError("fsync_parent")
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openDirectory(atCanonicalPath path: String) throws -> Int32 {
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
                if code == ELOOP || code == ENOTDIR {
                    throw SpiceLiveCampaignArtifactError.unsafePath
                }
                throw SpiceLiveCampaignArtifactError.ioFailure(
                    operation: "open_directory_identity",
                    code: code
                )
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func canonicalData<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func readAll(from descriptor: Int32, count: Int) throws -> Data {
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
            throw SpiceLiveCampaignArtifactError.invalidInput
        }
        data.removeSubrange(count..<data.count)
        return data
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw operationError("write_output") }
                offset += result
            }
        }
    }

    private static func canonicalDirectoryPath(_ path: String) -> String {
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
    ) -> SpiceLiveCampaignArtifactError {
        .ioFailure(operation: operation, code: errno)
    }
}
