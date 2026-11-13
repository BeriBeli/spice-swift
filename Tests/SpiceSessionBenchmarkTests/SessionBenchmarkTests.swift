import Foundation
import JavaScriptCore
import SpiceChannels
import SwiftSpice
import Testing

@testable import SpiceSessionBenchmark

@Suite("Real session benchmark")
struct SessionBenchmarkTests {
    private let markerToken = "1234567800000001"
    private let markerChecksum = SessionMarker.checksum(0x1234_5678_0000_0001)

    @Test func directVirtViewerPreservesTLSAndTicket() throws {
        let configuration = try BenchmarkConfiguration.fromVirtViewer(
            """
            \u{FEFF}[virt-viewer]\r
            type=spice\r
            host=192.0.2.1\r
            port=-1\r
            tls-port=61000\r
            password=secret=with=equals\r
            ca=-----BEGIN CERTIFICATE-----\\nTEST\\n-----END CERTIFICATE-----\r
            host-subject=OU=Cluster,O=Example,CN=node.example\r
            delete-this-file=1\r
            """)
        #expect(configuration.endpoint.host == "192.0.2.1")
        #expect(configuration.endpoint.port == 61000)
        #expect(configuration.password == "secret=with=equals")
        #expect(
            configuration.endpoint.tlsPolicy
                == .virtViewerCertificateAuthority(
                    certificates: [
                        Data("-----BEGIN CERTIFICATE-----\\nTEST\\n-----END CERTIFICATE-----".utf8)
                    ],
                    expectedSubject: "OU=Cluster,O=Example,CN=node.example"
                ))
    }

    @Test(arguments: [
        "proxy=http://proxy.example:3128", "host-subject=CN=other", "ca=PEM",
        "secure-channels=all", "tls-ciphers=CUSTOM", "host-key=pin", "port=0",
        "host=duplicate", "password=bad\u{0}value",
    ])
    func connectionFilesFailClosed(extra: String) {
        #expect(throws: (any Error).self) {
            try BenchmarkConfiguration.fromVirtViewer(
                "[virt-viewer]\ntype=spice\nhost=example\nport=5900\n" + extra)
        }
    }

    @Test func fileTicketCanBeOverriddenWithoutDeletingFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "benchmark-\(UUID()).vv")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(
            "[virt-viewer]\ntype=spice\nhost=example\nport=5900\npassword=original\ndelete-this-file=1\n"
                .utf8
        ).write(to: file)
        let config = try BenchmarkConfiguration.parse(
            [file.path, "--headless"], environment: ["SPICE_PASSWORD": "override"])
        #expect(config.password == "override")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func defaultCipherSelectionUsesSystemTLS() throws {
        let config = try BenchmarkConfiguration.fromVirtViewer(
            "[virt-viewer]\ntype=spice\nhost=example\ntls-port=5901\ntls-ciphers=DEFAULT\nsecure-channels=all\n"
        )
        #expect(config.endpoint.tlsPolicy == .system)
    }

    @Test(arguments: [
        ["--typo"], ["--observe-seconds", "0"], ["--observe-seconds", "NaN"],
        ["--enable-h264", "--enable-h265"], ["--tls", "--tls-insecure-for-testing-only"],
        ["--samples", "5"], ["--observe-seconds", "1", "--observe-seconds", "2"],
        ["--marker-base", "ffffffffffffffff", "--trace", "out.jsonl"],
        ["--marker-base", "1234567800000000", "--trace", "out.jsonl", "--headless"],
    ])
    func rejectsInvalidArguments(options: [String]) {
        #expect(throws: (any Error).self) {
            try BenchmarkConfiguration.parse(["example", "5900"] + options, environment: [:])
        }
    }

    @Test func statisticsExcludeInvalidRecordsAndOverlappingSendCompletion() {
        let accepted = record(sendCompleted: 250)
        #expect(accepted.valid)
        let invalid = record(sendCompleted: 160, invalidReason: "timeout")
        let stats = InteractionStatistics(records: [accepted, invalid])
        #expect(stats.attempted == 2)
        #expect(stats.valid == 1)
        #expect(stats.invalidReasons == ["timeout": 1])
        #expect(stats.sendCompletionOverlapsDisplay == 1)
        #expect(stats.stages["send_complete_to_display_receive"]?.count == 0)
        #expect(stats.stages["input_to_presented"]?.maximumMilliseconds == 0.0004)
        let percentiles = LatencyStatistics(nanoseconds: [5, 1, 4, 2, 3].map { $0 * 1_000_000 })
        #expect(percentiles.p50Milliseconds == 3)
        #expect(percentiles.p95Milliseconds == 5)
        #expect(LatencyStatistics(nanoseconds: []).p95Milliseconds == nil)
    }

    @Test func guestJavaScriptMarkerProducesAValidCorrelatedTrace() throws {
        let snapshot = try guestMarkerSnapshot()
        guard
            case .exact(let payload, _) = SpiceInteractionMarkerROIDetector.detect(
                in: snapshot, expectedToken: markerToken, expectedChecksum: markerChecksum
            )
        else {
            Issue.record("guest JavaScript marker was not decoded")
            return
        }
        #expect(payload.guestReceivedNs == 700)
        #expect(payload.guestMarkerDrawnNs == 800)
        let trace = try assembledTrace(from: snapshot)
        #expect(trace.valid)
        #expect(trace.guestReceivedNs == 700)
        #expect(trace.guestMarkerDrawnNs == 800)
        #expect(
            try JSONDecoder().decode(
                SpiceInteractionTraceRecord.self, from: JSONEncoder().encode(trace)) == trace)
    }

    @Test(arguments: [24, 32, 64])
    func incompleteOrMismatchedTimingCannotProduceAValidSample(height: Int) throws {
        let snapshot = try guestMarkerSnapshot(height: height, corruptTimingChecksum: height == 64)
        guard
            case .exact(let payload, _) = SpiceInteractionMarkerROIDetector.detect(
                in: snapshot, expectedToken: markerToken, expectedChecksum: markerChecksum
            )
        else {
            Issue.record("original event marker should remain detectable")
            return
        }
        #expect(payload.guestReceivedNs == nil)
        #expect(payload.guestMarkerDrawnNs == nil)
        let trace = try assembledTrace(from: snapshot)
        #expect(!trace.valid)
        #expect(trace.invalidReason == "missing_guest_received")
    }

    @Test func embeddedGuestTimestampsMustBeMonotonic() throws {
        let trace = try assembledTrace(from: guestMarkerSnapshot(guestReceivedNs: 900))
        #expect(!trace.valid)
        #expect(trace.invalidReason == "non_monotonic_timestamps")
    }

    @Test func timeoutCancelsSuspendedOperation() async {
        await #expect(throws: SessionBenchmarkError.timedOut) {
            try await withBenchmarkTimeout(seconds: 1) {
                try await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func guestMarkerSnapshot(
        height: Int = 64,
        guestReceivedNs: UInt64 = 700,
        corruptTimingChecksum: Bool = false
    ) throws -> SpiceDesktopSnapshot {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let context = try #require(JSContext())
        let script = try String(
            contentsOf: root.appending(path: "Benchmarks/Session/marker-grid.js"), encoding: .utf8)
        context.evaluateScript(script)
        let json = try #require(
            context.evaluateScript(
                "JSON.stringify(SpiceSessionMarker.encode(0x1234567800000001n, 1n, \(guestReceivedNs)n, 800n))"
            )?.toString())
        #expect(context.exception == nil)
        var grids = try JSONDecoder().decode([[UInt8]].self, from: Data(json.utf8))
        try #require(grids.map(\.count) == [176, 176])
        if corruptTimingChecksum { grids[1][175] ^= 1 }
        let width = 400
        var pixels = Data(repeating: 0x7f, count: width * height * 4)
        for (gridIndex, bits) in grids.enumerated() {
            for (bitIndex, bit) in bits.enumerated() {
                for y in 0..<4 {
                    let pixelY = 16 + gridIndex * 12 + bitIndex / 88 * 4 + y
                    guard pixelY < height else { continue }
                    for x in 0..<4 {
                        let offset = (pixelY * width + 16 + bitIndex % 88 * 4 + x) * 4
                        pixels.replaceSubrange(
                            offset..<(offset + 4),
                            with: [bit == 1 ? 0 : 255, bit == 1 ? 0 : 255, bit == 1 ? 0 : 255, 255])
                    }
                }
            }
        }
        return SpiceDesktopSnapshot(
            generation: 1,
            frame: SpiceFrameUpdate(
                frame: SpiceFrame(
                    surfaceID: 0, width: width, height: height, bytesPerRow: width * 4,
                    pixels: pixels),
                revision: SpiceFrameRevision(
                    surface: SpiceSurfaceIdentity(displayChannelID: 0, surfaceID: 0, generation: 1),
                    value: 1),
                damage: .full, deliverySequence: 1
            ), cursor: nil, pointerMode: .absolute, deliverySequence: 1
        )
    }

    private func assembledTrace(from snapshot: SpiceDesktopSnapshot) throws
        -> SpiceInteractionTraceRecord
    {
        let identity = try #require(snapshot.interactionFrameIdentity)
        let receiveInstant = ContinuousClock().now
        let receive = try #require(SpiceInteractionHostClock.nanoseconds(for: receiveInstant))
        let assembler = SpiceInteractionTraceAssembler(
            pairId: "test", version: "test", runId: "test", order: 1,
            actionClass: .key, token: markerToken, checksum: markerChecksum
        )
        assembler.recordHostEvidence(
            scheduledNs: receive - 100, hostInputNs: receive - 90, sendStartedNs: receive - 80,
            sendCompletedNs: receive - 70)
        assembler.observeFrame(
            snapshot: snapshot,
            sourceTiming: DisplayFrameSourceTiming(
                messageReceivedAt: receiveInstant, surfaceReadyAt: receiveInstant
            ))
        assembler.observeSelected(identity: identity, readyNs: receive, selectionNs: receive + 10)
        assembler.observeCommitted(identity: identity, at: receive + 20)
        assembler.observePresented(identity: identity, at: receive + 30)?.resume()
        return assembler.finish()
    }

    private func record(sendCompleted: UInt64, invalidReason: String? = nil)
        -> SpiceInteractionTraceRecord
    {
        SpiceInteractionTraceRecord(
            pairId: "test", version: "test", runId: "test", order: 1,
            actionClass: .key, token: "1234567800000001", scheduledNs: 90,
            hostInputNs: 100, sendStartedNs: 150, sendCompletedNs: sendCompleted,
            guestReceivedNs: 1, guestMarkerDrawnNs: 2, displayReceiveNs: 200,
            surfaceReadyNs: 300, selectedRevisionReadyNs: 310, selectionNs: 320,
            metalCommitNs: 400, presentedNs: 500, displayChannelID: 0, surfaceID: 0,
            surfaceGeneration: 1, desktopGeneration: 1, frameRevision: 1,
            deliverySequence: 1, markerRevision: 1, markerChecksum: "00000000",
            invalidReason: invalidReason
        )
    }
}
