import Darwin
import Foundation
import SwiftSpice

package struct SpiceLiveReadinessPermit: Sendable, Equatable {
    fileprivate let presentedFrames: UInt64
}

package struct SpiceLiveReadinessState: Sendable, Equatable {
    package let windowVisible: Bool
    package let windowOccluded: Bool
    package let hostingVisible: Bool
    package let visibleSubscriptions: Int
    package let metalPresentedFrames: UInt64

    package init(
        windowVisible: Bool,
        windowOccluded: Bool,
        hostingVisible: Bool,
        visibleSubscriptions: Int,
        metalPresentedFrames: UInt64
    ) {
        self.windowVisible = windowVisible
        self.windowOccluded = windowOccluded
        self.hostingVisible = hostingVisible
        self.visibleSubscriptions = visibleSubscriptions
        self.metalPresentedFrames = metalPresentedFrames
    }

    package var visibleDemandReady: Bool {
        windowVisible
            && !windowOccluded
            && hostingVisible
            && visibleSubscriptions == 1
    }

    package func permit(
        since baselinePresentedFrames: UInt64
    ) -> SpiceLiveReadinessPermit? {
        guard visibleDemandReady,
              metalPresentedFrames > baselinePresentedFrames else { return nil }
        return SpiceLiveReadinessPermit(presentedFrames: metalPresentedFrames)
    }
}

package enum SpiceLiveInputDispatchKind: String, Sendable, Equatable {
    case directSessionAPI = "direct_session_api"
}

package struct SpiceLiveInputDispatchMetadata: Sendable, Equatable {
    package let kind: SpiceLiveInputDispatchKind
    package let reportsAppKitReceipt: Bool

    package static let directSessionAPI = Self(
        kind: .directSessionAPI,
        reportsAppKitReceipt: false
    )
}

package struct SpiceLiveSingleRunExecution: Sendable {
    private enum Phase: Sendable {
        case ready(index: Int)
        case active(
            index: Int,
            exactPresented: Bool,
            localRecord: SpiceInteractionTraceRecord?
        )
        case completed
        case failed
    }

    private let steps: [SpiceLiveInteractionClusterPlan.Step]
    private var phase: Phase = .ready(index: 0)

    package var completed: Bool {
        if case .completed = phase { true } else { false }
    }

    package var failed: Bool {
        if case .failed = phase { true } else { false }
    }

    package init(steps: [SpiceLiveInteractionClusterPlan.Step]) throws {
        guard steps.count == 3,
              steps.map(\.order) == [1, 2, 3],
              steps.map(\.actionClass) == [.click, .key, .motion],
              Set(steps.map(\.token)).count == steps.count else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        self.steps = steps
    }

    package mutating func beginNextStep(
        readiness: SpiceLiveReadinessPermit?
    ) throws -> SpiceLiveInteractionClusterPlan.Step {
        guard case let .ready(index) = phase,
              steps.indices.contains(index),
              (index == 0 ? readiness != nil : readiness == nil) else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        phase = .active(index: index, exactPresented: false, localRecord: nil)
        return steps[index]
    }

    package mutating func recordExactPresentation(order: UInt64) throws {
        guard case let .active(index, false, nil) = phase,
              steps[index].order == order else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        phase = .active(index: index, exactPresented: true, localRecord: nil)
    }

    package mutating func recordLocalAppend(
        _ record: SpiceInteractionTraceRecord
    ) throws {
        guard case let .active(index, true, nil) = phase,
              recordMatchesStep(record, step: steps[index]),
              record.valid else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        phase = .active(index: index, exactPresented: true, localRecord: record)
    }

    package mutating func recordRemoteAppend(
        _ record: SpiceInteractionTraceRecord
    ) throws {
        guard case let .active(index, true, localRecord?) = phase,
              localRecord == record,
              recordMatchesStep(record, step: steps[index]),
              record.valid else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let next = index + 1
        phase = steps.indices.contains(next) ? .ready(index: next) : .completed
    }

    package mutating func fail() {
        phase = .failed
    }

    private func recordMatchesStep(
        _ record: SpiceInteractionTraceRecord,
        step: SpiceLiveInteractionClusterPlan.Step
    ) -> Bool {
        record.pairId == step.pairID
            && record.order == step.order
            && record.actionClass == step.actionClass
            && record.token == step.token
            && record.markerChecksum == String(format: "%08x", step.checksum)
    }
}

package enum SpiceLiveLocalOutput {
    package static func create(
        baseDirectory: URL,
        runID: String
    ) throws -> URL {
        guard baseDirectory.isFileURL,
              baseDirectory.baseURL == nil,
              SpiceLiveValidation.isCanonicalLowerHex(runID, count: 16) else {
            throw SpiceLiveInteractionSupportError.invalidConfiguration
        }
        let resolvedBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard resolvedBase.path.hasPrefix("/"),
              FileManager.default.fileExists(
                  atPath: resolvedBase.path,
                  isDirectory: &isDirectory
              ),
              isDirectory.boolValue else {
            throw SpiceLiveInteractionSupportError.invalidConfiguration
        }
        let directory = resolvedBase.appending(
            path: "swiftspice-live-\(runID)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, S_IRWXU) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw SpiceLiveInteractionSupportError.invalidConfiguration
        }
        return directory.appending(
            path: "input-events.jsonl",
            directoryHint: .notDirectory
        )
    }
}

package struct SpiceRemoteRunStatus: Sendable, Equatable {
    package let runDirectory: String
    package let evidenceRunID: String
    package let container: String
    package let spiceReady: Bool
    package let controlReady: Bool

    package init(
        result: SpiceLiveProcessResult,
        configuration: SpiceRemoteLiveConfiguration
    ) throws {
        let lines = result.outputLines
        let expectedPrefix = [
            "state=running",
            "container=\(configuration.container)",
            "spice=127.0.0.1:\(configuration.spicePort)",
            "control=127.0.0.1:\(configuration.controlPort)",
            "resolution=1280x720",
        ]
        guard result.status == 0,
              lines.count >= 6,
              Array(lines.prefix(5)) == expectedPrefix,
              lines[5].hasPrefix("run_evidence="),
              lines.filter({ $0 == "spice_listener=ready" }).count == 1,
              lines.filter({ $0 == "control_listener=ready" }).count == 1 else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let reservedPrefixes = [
            "state=", "container=", "spice=", "control=", "resolution=", "run_evidence=",
            "spice_listener=", "control_listener=",
        ]
        for prefix in reservedPrefixes {
            guard lines.filter({ $0.hasPrefix(prefix) }).count == 1 else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }
        }
        let runDirectory = String(lines[5].dropFirst("run_evidence=".count))
        guard Self.isCanonicalRunDirectory(
            runDirectory,
            base: configuration.base
        ) else {
            throw SpiceLiveInteractionSupportError.invalidRunDirectory
        }
        self.runDirectory = runDirectory
        evidenceRunID = String(runDirectory.dropFirst("\(configuration.base)/logs/".count))
        container = configuration.container
        spiceReady = true
        controlReady = true
    }

    package static func isCanonicalRunDirectory(
        _ value: String,
        base: String
    ) -> Bool {
        let prefix = "\(base)/logs/"
        guard value.hasPrefix(prefix),
              !value.dropFirst(prefix.count).contains("/") else { return false }
        let identifier = Array(value.dropFirst(prefix.count).utf8)
        guard identifier.count == 23,
              identifier[8] == 84,
              identifier[15] == 90,
              identifier[16] == 46 else { return false }
        return identifier[0..<8].allSatisfy(Self.isDigit)
            && identifier[9..<15].allSatisfy(Self.isDigit)
            && identifier[17..<23].allSatisfy(Self.isAlphaNumeric)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        isDigit(byte)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}

package struct SpiceRemoteGuestTrace: Sendable, Equatable {
    package let receivedNanoseconds: UInt64
    package let drawnNanoseconds: UInt64
    package let markerRevision: UInt64

    package init(lines: [String], actionClass: String, token: String) throws {
        guard lines.count == 3,
              lines[0] == "PERF_ARMED action_class=\(actionClass) token=\(token)",
              let received = Self.parse(lines[1], event: "guest_received"),
              let drawn = Self.parse(lines[2], event: "marker_drawn"),
              received.actionClass == actionClass,
              drawn.actionClass == actionClass,
              received.token == token,
              drawn.token == token,
              received.revision == drawn.revision,
              received.nanoseconds <= drawn.nanoseconds else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        receivedNanoseconds = received.nanoseconds
        drawnNanoseconds = drawn.nanoseconds
        markerRevision = received.revision
    }

    private static func parse(
        _ line: String,
        event: String
    ) -> (actionClass: String, token: String, nanoseconds: UInt64, revision: UInt64)? {
        let fields = line.split(separator: " ")
        guard fields.count == 6,
              fields[0] == "PERF_TRACE",
              fields[1] == "event=\(event)",
              fields[2].hasPrefix("action_class="),
              fields[3].hasPrefix("token="),
              fields[4].hasPrefix("guest_ns="),
              fields[5].hasPrefix("marker_revision="),
              let nanoseconds = UInt64(fields[4].dropFirst("guest_ns=".count)),
              let revision = UInt64(fields[5].dropFirst("marker_revision=".count)) else {
            return nil
        }
        return (
            String(fields[2].dropFirst("action_class=".count)),
            String(fields[3].dropFirst("token=".count)),
            nanoseconds,
            revision
        )
    }
}

package enum SpiceLiveCanonicalRecord {
    package static func encode(_ record: SpiceInteractionTraceRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var encoded = try encoder.encode(record)
        encoded.append(0x0A)
        guard encoded.count <= SpiceInteractionTraceJSONLWriter.maximumRecordBytes else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return encoded
    }

    package static func validate(_ encoded: Data) throws {
        _ = try decodeAndValidate(encoded)
    }

    package static func decodeAndValidate(
        _ encoded: Data
    ) throws -> SpiceInteractionTraceRecord {
        guard encoded.count <= SpiceInteractionTraceJSONLWriter.maximumRecordBytes,
              encoded.last == 0x0A else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let body = encoded.dropLast()
        let record = try JSONDecoder().decode(SpiceInteractionTraceRecord.self, from: body)
        guard try encode(record) == encoded else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return record
    }
}

package extension SpiceRemoteLiveConfiguration {
    static var maximumCollectorRecordBytes: Int {
        SpiceInteractionTraceJSONLWriter.maximumRecordBytes
    }

    func command(forRemoteScript script: String) throws -> SpiceRemoteCommand {
        guard ["status.sh", "ticket.sh"].contains(script) else {
            throw SpiceLiveInteractionSupportError.invalidConfiguration
        }
        return SpiceRemoteCommand(
            executable: "/usr/bin/ssh",
            arguments: sshArguments + ["\(paths.remoteDirectory)/\(script)"]
        )
    }

    func launchControlTrace(
        actionClass: String,
        token: String,
        runner: SpiceLiveProcessRunner = .ssh
    ) throws -> SpiceLiveChildProcess {
        guard ["click", "key", "motion"].contains(actionClass),
              SpiceLiveValidation.isCanonicalLowerHex(token, count: 16) else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return try runner.launch(arguments: sshArguments + [
            paths.controlScript, "trace", actionClass, token,
        ])
    }

    func collectorCommand(runDirectory: String) throws -> SpiceRemoteCommand {
        guard SpiceRemoteRunStatus.isCanonicalRunDirectory(
            runDirectory,
            base: base
        ) else {
            throw SpiceLiveInteractionSupportError.invalidRunDirectory
        }
        return SpiceRemoteCommand(
            executable: "/usr/bin/ssh",
            arguments: sshArguments + [
                "\(paths.remoteDirectory)/collect-input-events.sh", runDirectory,
            ]
        )
    }

    func appendRecord(
        _ record: Data,
        runDirectory: String,
        runner: SpiceLiveProcessRunner = .ssh
    ) async throws {
        let command = try collectorCommand(runDirectory: runDirectory)
        let decoded = try SpiceLiveCanonicalRecord.decodeAndValidate(record)
        let evidenceRunID = String(runDirectory.dropFirst("\(base)/logs/".count))
        guard decoded.runId == evidenceRunID else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let child = try runner.launch(arguments: command.arguments, standardInput: record)
        let result = try await child.finish(within: .seconds(20))
        guard result.status == 0,
              result.outputLines.count == 1,
              result.outputLines[0].hasPrefix("PERF_INPUT_EVENT_COLLECTED ") else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
    }

    func ticket(from result: SpiceLiveProcessResult) throws -> String {
        let output = result.standardOutput
        let ticket: String
        if output.utf8.count == 48 {
            ticket = output
        } else if output.utf8.count == 49, output.last == "\n" {
            ticket = String(output.dropLast())
        } else {
            throw SpiceLiveInteractionSupportError.invalidTicket
        }
        guard result.status == 0,
              SpiceLiveValidation.isCanonicalLowerHex(ticket, count: 48) else {
            throw SpiceLiveInteractionSupportError.invalidTicket
        }
        return ticket
    }
}
