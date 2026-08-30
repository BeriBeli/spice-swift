import Darwin
import Foundation
import Synchronization
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live stage driver")
struct SpiceLiveStageDriverTests {
    @Test func nineFramesPersistBeforeEveryACKAndCompleteOnce() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let frames = try Self.frames(fixture: fixture)
        let probe = TransportProbe(
            inbound: frames.map(TransportProbe.Inbound.frame),
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )

        #expect(await driver.state == .idle)
        try await withSpiceLiveTimeout(.seconds(2)) {
            try await driver.run()
        }
        #expect(await driver.state == .completed)

        let snapshot = await probe.snapshot()
        #expect(snapshot.receiveCalls == 9)
        #expect(snapshot.maximumConcurrentReaders == 1)
        #expect(
            snapshot.requestedMaximumBytes
                == Array(
                    repeating: SpiceLiveStageProtocolCodec.maximumFrameBytes,
                    count: 9
                )
        )
        #expect(snapshot.sendAttempts.count == 9)
        #expect(snapshot.completedFrames.count == 9)
        #expect(snapshot.partialWrites.isEmpty)
        #expect(snapshot.durabilityChecks == Array(repeating: true, count: 9))
        #expect(snapshot.closeCalls == 1)

        let acknowledgements = try snapshot.completedFrames.map {
            try SpiceLiveStageProtocolCodec.decodeAcknowledgement($0)
        }
        #expect(acknowledgements.map(\.eventSequence) == Array(1...9))
        #expect(
            acknowledgements.map(\.durableManifestGeneration)
                == Array(4...12)
        )
        let loaded = try fixture.writer.load()
        let manifest = try #require(loaded)
        #expect(manifest.generation == 12)
        #expect(manifest.stages.count == 12)
        #expect(manifest.state == .recording)
        #expect(fixture.gate.pendingAcknowledgement == nil)

        let bytes = try Data(contentsOf: fixture.output)
        let persistCalls = fixture.persistCalls.value
        try await driver.run()
        await driver.cancel()
        await driver.cancel()
        #expect(await driver.state == .completed)
        #expect(try Data(contentsOf: fixture.output) == bytes)
        #expect(fixture.persistCalls.value == persistCalls)
        let repeated = await probe.snapshot()
        #expect(repeated.receiveCalls == 9)
        #expect(repeated.sendAttempts.count == 9)
        #expect(repeated.closeCalls == 1)
    }

    @Test func concurrentRunKeepsExactlyOneReader() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let probe = TransportProbe(
            inbound: [.suspend],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let firstRun = Task { try await driver.run() }
        try await Self.waitUntil { await probe.snapshot().receiveCalls == 1 }
        #expect(await driver.state == .running)

        await #expect(throws: (any Error).self) {
            try await driver.run()
        }
        #expect(await driver.state == .running)
        let concurrent = await probe.snapshot()
        #expect(concurrent.receiveCalls == 1)
        #expect(concurrent.activeReaders == 1)
        #expect(concurrent.maximumConcurrentReaders == 1)

        firstRun.cancel()
        await #expect(throws: (any Error).self) {
            try await firstRun.value
        }
        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 0
        )
        let terminal = await probe.snapshot()
        #expect(terminal.maximumConcurrentReaders == 1)
    }

    @Test func cancellingDriverUnblocksASuspendedReceiveExactlyOnce() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let probe = TransportProbe(
            inbound: [.suspend],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let run = Task { try await driver.run() }
        try await Self.waitUntil {
            let snapshot = await probe.snapshot()
            return snapshot.activeReaders == 1
        }

        await driver.cancel()
        let afterCancellation = await probe.snapshot()
        #expect(afterCancellation.closeCalls == 1)
        await probe.emergencyReleaseSuspendedReceiveForTestCleanup()
        await #expect(throws: (any Error).self) {
            try await run.value
        }

        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 0
        )
        let terminal = await probe.snapshot()
        #expect(terminal.activeReaders == 0)
        #expect(terminal.maximumConcurrentReaders == 1)
    }

    @Test func taskCancellationClosesANoncooperativeSuspendedReceive() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let probe = TransportProbe(
            inbound: [.noncooperativeSuspend],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let run = Task { try await driver.run() }
        try await Self.waitUntil {
            await probe.snapshot().activeReaders == 1
        }

        run.cancel()
        let cancellationClosedTransport: Void? = try? await Self.waitUntil {
            await probe.snapshot().closeCalls == 1
        }
        let beforeCleanup = await probe.snapshot()
        #expect(cancellationClosedTransport != nil)
        #expect(beforeCleanup.closeCalls == 1)
        #expect(beforeCleanup.receiveCalls == 1)
        #expect(beforeCleanup.sendAttempts.isEmpty)

        await probe.emergencyReleaseSuspendedReceiveForTestCleanup()
        await #expect(throws: (any Error).self) {
            try await run.value
        }
        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 0
        )
        let terminal = await probe.snapshot()
        #expect(terminal.activeReaders == 0)
        #expect(terminal.maximumConcurrentReaders == 1)
    }

    @Test func cancellationReturningNilIsNotMisclassifiedAsEOF() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let probe = TransportProbe(
            inbound: [.returnNilOnTaskCancellation],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let run = Task { try await driver.run() }
        try await Self.waitUntil {
            await probe.snapshot().activeReaders == 1
        }

        run.cancel()
        let driverError: SpiceLiveStageDriver.DriverError
        do {
            try await run.value
            Issue.record("cancelled receive unexpectedly completed")
            return
        } catch let error as SpiceLiveStageDriver.DriverError {
            driverError = error
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
            return
        }
        #expect(driverError == .cancelled)

        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 0
        )
        let terminal = await probe.snapshot()
        #expect(terminal.activeReaders == 0)
        #expect(terminal.maximumConcurrentReaders == 1)
    }

    @Test func cancellationPersistenceFailureStillClosesSuspendedReceiveOnce() async throws {
        let fixture = try Self.fixture(failingDirectorySyncCall: 5)
        defer { Self.removeOutput(fixture.output) }
        let probe = TransportProbe(
            inbound: [.suspend],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let run = Task { try await driver.run() }
        try await Self.waitUntil {
            let snapshot = await probe.snapshot()
            return snapshot.activeReaders == 1
        }

        await driver.cancel()
        let afterCancellation = await probe.snapshot()
        #expect(afterCancellation.closeCalls == 1)
        await probe.emergencyReleaseSuspendedReceiveForTestCleanup()
        await #expect(throws: (any Error).self) {
            try await run.value
        }

        #expect(await driver.state == .terminal)
        #expect(fixture.gate.isTerminal)
        #expect(fixture.gate.pendingAcknowledgement == nil)
        #expect(fixture.persistCalls.value == 5)
        let loaded = try fixture.writer.load()
        let uncertainManifest = try #require(loaded)
        #expect(uncertainManifest.generation == 4)
        #expect(uncertainManifest.state == .failed)
        #expect(uncertainManifest.stages.count == 3)

        let uncertainBytes = try Data(contentsOf: fixture.output)
        let uncertainGeneration = uncertainManifest.generation
        let persistCalls = fixture.persistCalls.value
        let terminal = await probe.snapshot()
        #expect(terminal.receiveCalls == 1)
        #expect(terminal.activeReaders == 0)
        #expect(terminal.sendAttempts.isEmpty)
        #expect(terminal.closeCalls == 1)

        await #expect(throws: (any Error).self) {
            try await driver.run()
        }
        await driver.cancel()
        await driver.cancel()

        #expect(try Data(contentsOf: fixture.output) == uncertainBytes)
        let repeatedManifest = try fixture.writer.load()
        #expect(repeatedManifest?.generation == uncertainGeneration)
        #expect(fixture.persistCalls.value == persistCalls)
        let repeated = await probe.snapshot()
        #expect(repeated.receiveCalls == 1)
        #expect(repeated.activeReaders == 0)
        #expect(repeated.sendAttempts.isEmpty)
        #expect(repeated.closeCalls == 1)
    }

    @Test func cancellingIdleDriverDurablyTerminatesExactlyOnce() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let probe = TransportProbe(
            inbound: [.suspend],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let loadedBeforeCancel = try fixture.writer.load()
        let manifestBeforeCancel = try #require(loadedBeforeCancel)
        let persistCallsBeforeCancel = fixture.persistCalls.value
        #expect(manifestBeforeCancel.generation == 3)
        #expect(manifestBeforeCancel.state == .recording)
        #expect(await driver.state == .idle)

        await driver.cancel()

        #expect(await driver.state == .terminal)
        let loadedAfterCancel = try fixture.writer.load()
        let manifestAfterCancel = try #require(loadedAfterCancel)
        #expect(manifestAfterCancel.generation == 4)
        #expect(manifestAfterCancel.state == .failed)
        #expect(fixture.persistCalls.value == persistCallsBeforeCancel + 1)
        let afterCancel = await probe.snapshot()
        #expect(afterCancel.receiveCalls == 0)
        #expect(afterCancel.sendAttempts.isEmpty)
        #expect(afterCancel.closeCalls == 1)

        let terminalBytes = try Data(contentsOf: fixture.output)
        let terminalGeneration = manifestAfterCancel.generation
        let terminalPersistCalls = fixture.persistCalls.value
        await driver.cancel()
        await driver.cancel()
        await #expect(throws: (any Error).self) {
            try await driver.run()
        }

        #expect(await driver.state == .terminal)
        let repeatedBytes = try Data(contentsOf: fixture.output)
        let repeatedManifest = try fixture.writer.load()
        let repeated = await probe.snapshot()
        #expect(repeatedBytes == terminalBytes)
        #expect(repeatedManifest?.generation == terminalGeneration)
        #expect(fixture.persistCalls.value == terminalPersistCalls)
        #expect(repeated.receiveCalls == 0)
        #expect(repeated.sendAttempts.isEmpty)
        #expect(repeated.closeCalls == 1)
    }

    @Test(
        "Malformed, oversized, EOF, and receive failures are durable once",
        arguments: InputFailure.allCases
    )
    fileprivate func inputFailureIsTerminalOnce(
        failure: InputFailure
    ) async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let probe = TransportProbe(
            inbound: [failure.inbound],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )

        await #expect(throws: (any Error).self) {
            try await withSpiceLiveTimeout(.seconds(2)) {
                try await driver.run()
            }
        }
        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 0
        )
        let snapshot = await probe.snapshot()
        #expect(
            snapshot.requestedMaximumBytes
                == [SpiceLiveStageProtocolCodec.maximumFrameBytes]
        )
    }

    @Test(
        "Transport-originated DriverErrors are receive failures",
        arguments: TransportDriverFailure.allCases
    )
    fileprivate func transportDriverErrorsCannotEscapeTheTerminalTransition(
        _ failure: TransportDriverFailure
    ) async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let probe = TransportProbe(
            inbound: [.driverFailure(failure.error)],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )

        let driverError: SpiceLiveStageDriver.DriverError
        do {
            try await driver.run()
            Issue.record("transport DriverError unexpectedly completed")
            return
        } catch let error as SpiceLiveStageDriver.DriverError {
            driverError = error
        } catch {
            Issue.record("unexpected receive error: \(error)")
            return
        }
        #expect(driverError == .receiveFailed)

        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 0
        )
        let terminal = await probe.snapshot()
        #expect(terminal.activeReaders == 0)
        #expect(terminal.maximumConcurrentReaders == 1)
    }

    @Test func childStagePersistenceFailureSendsNoACKAndIsTerminalOnce() async throws {
        let fixture = try Self.fixture(failingDirectorySyncCall: 5)
        defer { Self.removeOutput(fixture.output) }
        let firstFrame = try #require(Self.frames(fixture: fixture).first)
        let probe = TransportProbe(
            inbound: [.frame(firstFrame)],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )

        await #expect(throws: (any Error).self) {
            try await withSpiceLiveTimeout(.seconds(2)) {
                try await driver.run()
            }
        }

        #expect(await driver.state == .terminal)
        #expect(fixture.gate.isTerminal)
        #expect(fixture.gate.pendingAcknowledgement == nil)
        #expect(fixture.persistCalls.value == 5)
        let loaded = try fixture.writer.load()
        let uncertainManifest = try #require(loaded)
        #expect(uncertainManifest.generation == 4)
        #expect(uncertainManifest.state == .recording)
        #expect(uncertainManifest.stages.count == 4)
        #expect(uncertainManifest.stages.last?.stage == .preArm)
        #expect(uncertainManifest.stages.last?.outcome == .succeeded)

        let uncertainBytes = try Data(contentsOf: fixture.output)
        let uncertainGeneration = uncertainManifest.generation
        let persistCalls = fixture.persistCalls.value
        let terminal = await probe.snapshot()
        #expect(terminal.receiveCalls == 1)
        #expect(terminal.sendAttempts.isEmpty)
        #expect(terminal.closeCalls == 1)

        await #expect(throws: (any Error).self) {
            try await driver.run()
        }
        await driver.cancel()
        await driver.cancel()

        #expect(try Data(contentsOf: fixture.output) == uncertainBytes)
        let repeatedManifest = try fixture.writer.load()
        #expect(repeatedManifest?.generation == uncertainGeneration)
        #expect(fixture.persistCalls.value == persistCalls)
        let repeated = await probe.snapshot()
        #expect(repeated.receiveCalls == 1)
        #expect(repeated.sendAttempts.isEmpty)
        #expect(repeated.closeCalls == 1)
    }

    @Test(
        "Send throw and partial write never deliver or retry an ACK",
        arguments: SendFailure.allCases
    )
    fileprivate func sendFailureIsTerminalOnce(
        failure: SendFailure
    ) async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let firstFrame = try #require(Self.frames(fixture: fixture).first)
        let probe = TransportProbe(
            inbound: [.frame(firstFrame)],
            sendBehavior: failure.behavior,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )

        await #expect(throws: (any Error).self) {
            try await withSpiceLiveTimeout(.seconds(2)) {
                try await driver.run()
            }
        }
        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 1
        )
        let snapshot = await probe.snapshot()
        #expect(snapshot.completedFrames.isEmpty)
        #expect(snapshot.durabilityChecks == [true])
        let acknowledgement = try SpiceLiveStageProtocolCodec
            .decodeAcknowledgement(snapshot.sendAttempts[0])
        #expect(fixture.gate.pendingAcknowledgement == acknowledgement)
        switch failure {
        case .throwBeforeWrite:
            #expect(snapshot.partialWrites.isEmpty)
        case .partialWrite:
            #expect(snapshot.partialWrites.count == 1)
            #expect(snapshot.partialWrites[0].count == 17)
            #expect(snapshot.partialWrites[0] != snapshot.sendAttempts[0])
        }
    }

    @Test func acknowledgementFailurePersistenceErrorClosesAndIsTerminalOnce() async throws {
        let fixture = try Self.fixture(failingDirectorySyncCall: 6)
        defer { Self.removeOutput(fixture.output) }
        let firstFrame = try #require(Self.frames(fixture: fixture).first)
        let probe = TransportProbe(
            inbound: [.frame(firstFrame)],
            sendBehavior: .failBeforeWrite,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )

        await #expect(throws: (any Error).self) {
            try await driver.run()
        }

        #expect(await driver.state == .terminal)
        #expect(fixture.gate.isTerminal)
        #expect(fixture.persistCalls.value == 6)
        let terminal = await probe.snapshot()
        #expect(terminal.receiveCalls == 1)
        #expect(terminal.sendAttempts.count == 1)
        #expect(terminal.completedFrames.isEmpty)
        #expect(terminal.closeCalls == 1)
        let acknowledgement = try SpiceLiveStageProtocolCodec
            .decodeAcknowledgement(terminal.sendAttempts[0])
        #expect(fixture.gate.pendingAcknowledgement == acknowledgement)

        let loaded = try fixture.writer.load()
        let uncertainManifest = try #require(loaded)
        #expect(uncertainManifest.generation == 5)
        #expect(uncertainManifest.state == .failed)
        #expect(uncertainManifest.stages.count == 4)
        #expect(uncertainManifest.stages.last?.stage == .preArm)
        #expect(uncertainManifest.stages.last?.outcome == .succeeded)

        let uncertainBytes = try Data(contentsOf: fixture.output)
        let uncertainGeneration = uncertainManifest.generation
        let persistCalls = fixture.persistCalls.value
        await #expect(throws: (any Error).self) {
            try await driver.run()
        }
        await driver.cancel()
        await driver.cancel()

        #expect(try Data(contentsOf: fixture.output) == uncertainBytes)
        let repeatedManifest = try fixture.writer.load()
        #expect(repeatedManifest?.generation == uncertainGeneration)
        #expect(fixture.persistCalls.value == persistCalls)
        #expect(fixture.gate.pendingAcknowledgement == acknowledgement)
        let repeated = await probe.snapshot()
        #expect(repeated.receiveCalls == 1)
        #expect(repeated.sendAttempts.count == 1)
        #expect(repeated.completedFrames.isEmpty)
        #expect(repeated.closeCalls == 1)
    }

    @Test func cancellingASuspendedSendClosesAndPoisonsExactlyOnce() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let firstFrame = try #require(Self.frames(fixture: fixture).first)
        let probe = TransportProbe(
            inbound: [.frame(firstFrame)],
            sendBehavior: .suspend(resumeSuccessfullyWhenClosed: false),
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let run = Task { try await driver.run() }
        try await Self.waitUntil { await probe.snapshot().sendAttempts.count == 1 }

        let durableBeforeCancellation = try fixture.writer.load()
        #expect(durableBeforeCancellation?.generation == 4)
        #expect(durableBeforeCancellation?.stages.last?.stage == .preArm)
        #expect(await driver.state == .running)
        run.cancel()
        await #expect(throws: (any Error).self) {
            try await run.value
        }

        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 1
        )
        let snapshot = await probe.snapshot()
        #expect(snapshot.completedFrames.isEmpty)
        #expect(snapshot.sendCancellations == 1)
        let acknowledgement = try SpiceLiveStageProtocolCodec
            .decodeAcknowledgement(snapshot.sendAttempts[0])
        #expect(fixture.gate.pendingAcknowledgement == acknowledgement)
    }

    @Test func taskCancellationClosesANoncooperativeSuspendedSend() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let firstFrame = try #require(Self.frames(fixture: fixture).first)
        let probe = TransportProbe(
            inbound: [.frame(firstFrame)],
            sendBehavior: .noncooperativeSuspend,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let run = Task { try await driver.run() }
        try await Self.waitUntil {
            await probe.snapshot().sendAttempts.count == 1
        }
        let sent = await probe.snapshot()
        let acknowledgement = try SpiceLiveStageProtocolCodec
            .decodeAcknowledgement(sent.sendAttempts[0])
        #expect(fixture.gate.pendingAcknowledgement == acknowledgement)

        run.cancel()
        let cancellationClosedTransport: Void? = try? await Self.waitUntil {
            await probe.snapshot().closeCalls == 1
        }
        let beforeCleanup = await probe.snapshot()
        #expect(cancellationClosedTransport != nil)
        #expect(beforeCleanup.closeCalls == 1)
        #expect(beforeCleanup.receiveCalls == 1)
        #expect(beforeCleanup.sendAttempts.count == 1)
        #expect(beforeCleanup.completedFrames.isEmpty)

        await probe.emergencyReleaseSuspendedSendForTestCleanup()
        await #expect(throws: (any Error).self) {
            try await run.value
        }
        try await Self.assertTerminalOnce(
            driver: driver,
            probe: probe,
            fixture: fixture,
            expectedReceiveCalls: 1,
            expectedSendAttempts: 1
        )
        let terminal = await probe.snapshot()
        #expect(terminal.completedFrames.isEmpty)
        #expect(fixture.gate.pendingAcknowledgement == acknowledgement)
    }

    @Test func cancelWinningASendRaceCannotAdvanceTheGate() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let firstFrame = try #require(Self.frames(fixture: fixture).first)
        let probe = TransportProbe(
            inbound: [.frame(firstFrame)],
            sendBehavior: .suspend(resumeSuccessfullyWhenClosed: true),
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )
        let run = Task { try await driver.run() }
        try await Self.waitUntil { await probe.snapshot().sendAttempts.count == 1 }
        #expect(fixture.gate.pendingAcknowledgement != nil)

        await driver.cancel()
        let afterCancellation = await probe.snapshot()
        #expect(afterCancellation.closeCalls == 1)
        await probe.emergencyReleaseSuspendedSendForTestCleanup()
        await #expect(throws: (any Error).self) {
            try await run.value
        }
        #expect(await driver.state == .terminal)
        let loaded = try fixture.writer.load()
        let manifest = try #require(loaded)
        #expect(manifest.state == .failed)
        #expect(manifest.stages.count == 4)
        #expect(manifest.stages.last?.stage == .preArm)

        let snapshot = await probe.snapshot()
        #expect(snapshot.receiveCalls == 1)
        #expect(snapshot.sendAttempts.count == 1)
        #expect(snapshot.completedFrames.count == 1)
        #expect(snapshot.closeCalls == 1)
        let acknowledgement = try SpiceLiveStageProtocolCodec
            .decodeAcknowledgement(snapshot.sendAttempts[0])
        #expect(fixture.gate.pendingAcknowledgement == acknowledgement)
        let bytes = try Data(contentsOf: fixture.output)
        let persistCalls = fixture.persistCalls.value
        await driver.cancel()
        await driver.cancel()
        #expect(try Data(contentsOf: fixture.output) == bytes)
        #expect(fixture.persistCalls.value == persistCalls)
        let repeated = await probe.snapshot()
        #expect(repeated.receiveCalls == 1)
        #expect(repeated.sendAttempts.count == 1)
        #expect(repeated.closeCalls == 1)
    }

    @Test func failedChildEventIsACKedThenTerminatesWithoutReadingAgain() async throws {
        let fixture = try Self.fixture()
        defer { Self.removeOutput(fixture.output) }
        let event = try Self.event(
            fixture: fixture,
            step: fixture.run.steps[0],
            stage: .preArm,
            outcome: .failed,
            sequence: 1,
            previousGeneration: 3
        )
        let frame = try SpiceLiveStageProtocolCodec.encodeEvent(event)
        let probe = TransportProbe(
            inbound: [.frame(frame), .suspend],
            sendBehavior: .succeed,
            manifestURL: fixture.output
        )
        let driver = SpiceLiveStageDriver(
            gate: fixture.gate,
            transport: Self.transport(probe)
        )

        await #expect(throws: (any Error).self) {
            try await withSpiceLiveTimeout(.seconds(2)) {
                try await driver.run()
            }
        }
        #expect(await driver.state == .terminal)
        let snapshot = await probe.snapshot()
        #expect(snapshot.receiveCalls == 1)
        #expect(snapshot.sendAttempts.count == 1)
        #expect(snapshot.completedFrames.count == 1)
        #expect(snapshot.closeCalls == 1)
        let acknowledgement = try SpiceLiveStageProtocolCodec
            .decodeAcknowledgement(snapshot.completedFrames[0])
        #expect(acknowledgement.outcome == .failed)
        #expect(acknowledgement.durableManifestGeneration == 4)
        let loaded = try fixture.writer.load()
        let manifest = try #require(loaded)
        #expect(manifest.generation == 4)
        #expect(manifest.state == .failed)
        #expect(manifest.stages.count == 4)
        #expect(fixture.gate.pendingAcknowledgement == nil)

        let bytes = try Data(contentsOf: fixture.output)
        let persistCalls = fixture.persistCalls.value
        await #expect(throws: (any Error).self) {
            try await driver.run()
        }
        await driver.cancel()
        #expect(try Data(contentsOf: fixture.output) == bytes)
        #expect(fixture.persistCalls.value == persistCalls)
        let repeated = await probe.snapshot()
        #expect(repeated.receiveCalls == 1)
        #expect(repeated.sendAttempts.count == 1)
        #expect(repeated.closeCalls == 1)
    }
}

private extension SpiceLiveStageDriverTests {
    enum ProbeFailure: Error, Sendable {
        case receive
        case send
        case partialWrite
        case acknowledgementBeforeDurability
    }

    enum InputFailure: CaseIterable, CustomTestStringConvertible {
        case malformed
        case oversized
        case endOfFile
        case receiveError

        var testDescription: String {
            switch self {
            case .malformed: "malformed"
            case .oversized: "oversized"
            case .endOfFile: "EOF"
            case .receiveError: "receive error"
            }
        }

        var inbound: TransportProbe.Inbound {
            switch self {
            case .malformed:
                .frame(Data("{\"malformed\":true}\n".utf8))
            case .oversized:
                .frame(Data(
                    repeating: 0x78,
                    count: SpiceLiveStageProtocolCodec.maximumFrameBytes + 1
                ))
            case .endOfFile:
                .endOfFile
            case .receiveError:
                .failure(.receive)
            }
        }
    }

    enum TransportDriverFailure: CaseIterable, CustomTestStringConvertible {
        case alreadyRunning
        case terminal
        case unexpectedEndOfFile
        case cancelled
        case receiveFailed
        case invalidEventFrame
        case acknowledgementEncodingFailed
        case acknowledgementSendFailed
        case childReportedFailure

        var testDescription: String {
            switch self {
            case .alreadyRunning: "already running"
            case .terminal: "terminal"
            case .unexpectedEndOfFile: "unexpected EOF"
            case .cancelled: "cancelled"
            case .receiveFailed: "receive failed"
            case .invalidEventFrame: "invalid event frame"
            case .acknowledgementEncodingFailed: "ACK encoding failed"
            case .acknowledgementSendFailed: "ACK send failed"
            case .childReportedFailure: "child reported failure"
            }
        }

        var error: SpiceLiveStageDriver.DriverError {
            switch self {
            case .alreadyRunning: .alreadyRunning
            case .terminal: .terminal
            case .unexpectedEndOfFile: .unexpectedEndOfFile
            case .cancelled: .cancelled
            case .receiveFailed: .receiveFailed
            case .invalidEventFrame: .invalidEventFrame
            case .acknowledgementEncodingFailed:
                .acknowledgementEncodingFailed
            case .acknowledgementSendFailed: .acknowledgementSendFailed
            case .childReportedFailure: .childReportedFailure
            }
        }
    }

    enum SendFailure: CaseIterable, CustomTestStringConvertible {
        case throwBeforeWrite
        case partialWrite

        var testDescription: String {
            switch self {
            case .throwBeforeWrite: "throw before write"
            case .partialWrite: "partial write"
            }
        }

        var behavior: TransportProbe.SendBehavior {
            switch self {
            case .throwBeforeWrite: .failBeforeWrite
            case .partialWrite: .partialWrite(byteCount: 17)
            }
        }
    }

    final class PersistenceCounter: Sendable {
        private let storage = Mutex(0)

        var value: Int { storage.withLock { $0 } }

        @discardableResult
        func increment() -> Int {
            storage.withLock {
                $0 += 1
                return $0
            }
        }
    }

    struct Fixture {
        let plan: SpiceLiveCampaignPlan
        let run: SpiceLiveCampaignRun
        let evidenceRunID: SpiceLiveEvidenceRunID
        let writer: SpiceLiveCampaignManifestWriter
        let recorder: SpiceLiveRealtimeStageRecorder
        let gate: SpiceLiveDurableStageGate
        let output: URL
        let persistCalls: PersistenceCounter
    }

    actor TransportProbe {
        enum Inbound: Sendable {
            case frame(Data)
            case endOfFile
            case failure(ProbeFailure)
            case driverFailure(SpiceLiveStageDriver.DriverError)
            case suspend
            case noncooperativeSuspend
            case returnNilOnTaskCancellation
        }

        enum SendBehavior: Sendable {
            case succeed
            case failBeforeWrite
            case partialWrite(byteCount: Int)
            case suspend(resumeSuccessfullyWhenClosed: Bool)
            case noncooperativeSuspend
        }

        struct Snapshot: Sendable {
            let receiveCalls: Int
            let activeReaders: Int
            let maximumConcurrentReaders: Int
            let requestedMaximumBytes: [Int]
            let sendAttempts: [Data]
            let completedFrames: [Data]
            let partialWrites: [Data]
            let durabilityChecks: [Bool]
            let sendCancellations: Int
            let closeCalls: Int
        }

        private var inbound: [Inbound]
        private let sendBehavior: SendBehavior
        private let manifestURL: URL
        private var receiveCalls = 0
        private var activeReaders = 0
        private var maximumConcurrentReaders = 0
        private var requestedMaximumBytes: [Int] = []
        private var sendAttempts: [Data] = []
        private var completedFrames: [Data] = []
        private var partialWrites: [Data] = []
        private var durabilityChecks: [Bool] = []
        private var sendCancellations = 0
        private var closeCalls = 0
        private var suspendedReceive: CheckedContinuation<Data?, any Error>?
        private var suspendedSend: CheckedContinuation<Void, any Error>?
        private var receiveCancellationRequested = false
        private var sendCancellationRequested = false
        private let cancellationReturningNil = CancellationReturningNil()

        init(
            inbound: [Inbound],
            sendBehavior: SendBehavior,
            manifestURL: URL
        ) {
            self.inbound = inbound
            self.sendBehavior = sendBehavior
            self.manifestURL = manifestURL
        }

        func receiveFrame(maximumBytes: Int) async throws -> Data? {
            receiveCalls += 1
            activeReaders += 1
            maximumConcurrentReaders = max(maximumConcurrentReaders, activeReaders)
            requestedMaximumBytes.append(maximumBytes)
            defer { activeReaders -= 1 }
            guard !inbound.isEmpty else { return nil }
            switch inbound.removeFirst() {
            case let .frame(frame):
                return frame
            case .endOfFile:
                return nil
            case let .failure(error):
                throw error
            case let .driverFailure(error):
                throw error
            case .suspend:
                return try await withTaskCancellationHandler(
                    operation: {
                        try await withCheckedThrowingContinuation {
                            (
                                continuation: CheckedContinuation<
                                    Data?,
                                    any Error
                                >
                            ) in
                            if receiveCancellationRequested {
                                receiveCancellationRequested = false
                                continuation.resume(
                                    throwing: CancellationError()
                                )
                            } else {
                                suspendedReceive = continuation
                            }
                        }
                    },
                    onCancel: {
                        Task { await self.cancelSuspendedReceive() }
                    }
                )
            case .noncooperativeSuspend:
                return try await withCheckedThrowingContinuation {
                    suspendedReceive = $0
                }
            case .returnNilOnTaskCancellation:
                return await cancellationReturningNil.receive()
            }
        }

        func sendFrame(_ frame: Data) async throws {
            sendAttempts.append(frame)
            let acknowledgement = try SpiceLiveStageProtocolCodec
                .decodeAcknowledgement(frame)
            let bytes = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(
                SpiceLiveCampaignManifest.self,
                from: bytes
            )
            let canonical = try SpiceLiveStageDriverTests
                .canonicalManifestData(manifest)
            let durable = bytes == canonical
                && manifest.generation
                    == acknowledgement.durableManifestGeneration
            durabilityChecks.append(durable)
            guard durable else {
                throw ProbeFailure.acknowledgementBeforeDurability
            }

            switch sendBehavior {
            case .succeed:
                completedFrames.append(frame)
            case .failBeforeWrite:
                throw ProbeFailure.send
            case let .partialWrite(byteCount):
                partialWrites.append(Data(frame.prefix(byteCount)))
                throw ProbeFailure.partialWrite
            case let .suspend(resumeSuccessfullyWhenClosed):
                do {
                    try await withTaskCancellationHandler(
                        operation: {
                            try await withCheckedThrowingContinuation {
                                (
                                    continuation: CheckedContinuation<
                                        Void,
                                        any Error
                                    >
                                ) in
                                if sendCancellationRequested {
                                    sendCancellationRequested = false
                                    continuation.resume(
                                        throwing: CancellationError()
                                    )
                                } else {
                                    suspendedSend = continuation
                                }
                            }
                        },
                        onCancel: {
                            Task { await self.cancelSuspendedSend() }
                        }
                    )
                    if resumeSuccessfullyWhenClosed {
                        completedFrames.append(frame)
                    }
                } catch {
                    throw error
                }
            case .noncooperativeSuspend:
                try await withCheckedThrowingContinuation {
                    suspendedSend = $0
                }
            }
        }

        func close() {
            closeCalls += 1
            cancellationReturningNil.release()
            if let continuation = suspendedReceive {
                suspendedReceive = nil
                continuation.resume(throwing: CancellationError())
            }
            if let continuation = suspendedSend {
                suspendedSend = nil
                switch sendBehavior {
                case .suspend(resumeSuccessfullyWhenClosed: true):
                    continuation.resume()
                case .suspend, .noncooperativeSuspend,
                     .succeed, .failBeforeWrite, .partialWrite:
                    continuation.resume(throwing: CancellationError())
                }
            }
        }

        func snapshot() -> Snapshot {
            Snapshot(
                receiveCalls: receiveCalls,
                activeReaders: activeReaders,
                maximumConcurrentReaders: maximumConcurrentReaders,
                requestedMaximumBytes: requestedMaximumBytes,
                sendAttempts: sendAttempts,
                completedFrames: completedFrames,
                partialWrites: partialWrites,
                durabilityChecks: durabilityChecks,
                sendCancellations: sendCancellations,
                closeCalls: closeCalls
            )
        }

        func emergencyReleaseSuspendedReceiveForTestCleanup() {
            cancellationReturningNil.release()
            guard let continuation = suspendedReceive else { return }
            suspendedReceive = nil
            continuation.resume(throwing: CancellationError())
        }

        func emergencyReleaseSuspendedSendForTestCleanup() {
            guard let continuation = suspendedSend else { return }
            suspendedSend = nil
            continuation.resume(throwing: CancellationError())
        }

        private func cancelSuspendedReceive() {
            guard let continuation = suspendedReceive else {
                receiveCancellationRequested = true
                return
            }
            suspendedReceive = nil
            continuation.resume(throwing: CancellationError())
        }

        private func cancelSuspendedSend() {
            sendCancellations += 1
            guard let continuation = suspendedSend else {
                sendCancellationRequested = true
                return
            }
            suspendedSend = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    final class CancellationReturningNil: Sendable {
        private struct Storage {
            var continuation: CheckedContinuation<Data?, Never>?
            var cancellationObserved = false
        }

        private let storage = Mutex(Storage())

        func receive() async -> Data? {
            await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { continuation in
                        let resumeImmediately = storage.withLock { storage in
                            if storage.cancellationObserved {
                                storage.cancellationObserved = false
                                return true
                            }
                            storage.continuation = continuation
                            return false
                        }
                        if resumeImmediately {
                            continuation.resume(returning: nil)
                        }
                    }
                },
                onCancel: { release() }
            )
        }

        func release() {
            let continuation = storage.withLock { storage in
                guard let continuation = storage.continuation else {
                    storage.cancellationObserved = true
                    return nil as CheckedContinuation<Data?, Never>?
                }
                storage.continuation = nil
                return continuation
            }
            continuation?.resume(returning: nil)
        }
    }

    static func transport(_ probe: TransportProbe) -> SpiceLiveStageTransport {
        SpiceLiveStageTransport(
            receiveFrame: { maximumBytes in
                try await probe.receiveFrame(maximumBytes: maximumBytes)
            },
            sendFrame: { frame in
                try await probe.sendFrame(frame)
            },
            close: {
                await probe.close()
            }
        )
    }

    static func assertTerminalOnce(
        driver: SpiceLiveStageDriver,
        probe: TransportProbe,
        fixture: Fixture,
        expectedReceiveCalls: Int,
        expectedSendAttempts: Int
    ) async throws {
        #expect(await driver.state == .terminal)
        let loaded = try fixture.writer.load()
        let manifest = try #require(loaded)
        #expect(manifest.state == .failed)
        let terminalBytes = try Data(contentsOf: fixture.output)
        let terminalGeneration = manifest.generation
        let terminalPersistCalls = fixture.persistCalls.value
        let beforeRepeat = await probe.snapshot()
        #expect(beforeRepeat.receiveCalls == expectedReceiveCalls)
        #expect(beforeRepeat.sendAttempts.count == expectedSendAttempts)
        #expect(beforeRepeat.closeCalls == 1)

        await #expect(throws: (any Error).self) {
            try await driver.run()
        }
        await driver.cancel()
        await driver.cancel()

        let repeatedBytes = try Data(contentsOf: fixture.output)
        let repeatedManifest = try fixture.writer.load()
        let afterRepeat = await probe.snapshot()
        #expect(repeatedBytes == terminalBytes)
        #expect(repeatedManifest?.generation == terminalGeneration)
        #expect(fixture.persistCalls.value == terminalPersistCalls)
        #expect(afterRepeat.receiveCalls == expectedReceiveCalls)
        #expect(afterRepeat.sendAttempts.count == expectedSendAttempts)
        #expect(afterRepeat.closeCalls == 1)
    }

    static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await withSpiceLiveTimeout(.seconds(2)) {
            while !(await condition()) {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    static func fixture(
        failingDirectorySyncCall: Int? = nil
    ) throws -> Fixture {
        let plan = try campaignPlan()
        let metadata = try campaignMetadata()
        let output = try outputURL()
        let persistCalls = PersistenceCounter()
        let writer = try SpiceLiveCampaignManifestWriter(
            outputURL: output,
            directorySync: { descriptor in
                let call = persistCalls.increment()
                if call == failingDirectorySyncCall {
                    throw SpiceLiveCampaignManifestError.fileOperationFailed(
                        operation: "fsync_directory",
                        code: EIO
                    )
                }
                guard Darwin.fsync(descriptor) == 0 else {
                    throw SpiceLiveCampaignManifestError.fileOperationFailed(
                        operation: "fsync_directory",
                        code: errno
                    )
                }
            }
        )
        let recorder = try SpiceLiveRealtimeStageRecorder(
            plan: plan,
            metadata: metadata,
            executionContract: campaignExecutionContract(
                plan: plan,
                metadata: metadata
            ),
            manifestWriter: writer
        )
        let run = plan.runs[0]
        let evidenceRunID = try SpiceLiveEvidenceRunID(
            "20260831T000000Z.A1b2C3"
        )
        try recorder.record(
            run: run,
            stage: .fixtureStop,
            outcome: .succeeded
        )
        try recorder.record(
            run: run,
            stage: .fixtureStart,
            outcome: .succeeded,
            evidenceRunID: evidenceRunID
        )
        try recorder.record(
            run: run,
            stage: .fixtureHealth,
            outcome: .succeeded
        )
        let gate = try SpiceLiveDurableStageGate(
            plan: plan,
            recorder: recorder
        )
        return Fixture(
            plan: plan,
            run: run,
            evidenceRunID: evidenceRunID,
            writer: writer,
            recorder: recorder,
            gate: gate,
            output: output,
            persistCalls: persistCalls
        )
    }

    static func frames(fixture: Fixture) throws -> [Data] {
        var frames: [Data] = []
        var eventSequence: UInt64 = 1
        var previousGeneration: UInt64 = 3
        for step in fixture.run.steps {
            for stage in actionStages {
                let event = try event(
                    fixture: fixture,
                    step: step,
                    stage: stage,
                    sequence: eventSequence,
                    previousGeneration: previousGeneration
                )
                frames.append(try SpiceLiveStageProtocolCodec.encodeEvent(event))
                eventSequence += 1
                previousGeneration += 1
            }
        }
        return frames
    }

    static func event(
        fixture: Fixture,
        step: SpiceLiveInteractionClusterPlan.Step,
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome = .succeeded,
        sequence: UInt64,
        previousGeneration: UInt64
    ) throws -> SpiceLiveChildStageEvent {
        try SpiceLiveChildStageEvent(
            protocolVersion: .v1,
            campaignID: fixture.run.campaignID,
            runID: fixture.run.runID,
            version: fixture.run.version,
            clusterID: fixture.run.clusterID,
            evidenceRunID: fixture.evidenceRunID,
            actionClass: step.actionClass,
            order: step.order,
            token: step.token,
            checksum: step.checksum,
            stage: stage,
            outcome: outcome,
            eventSequence: sequence,
            previousManifestGeneration: previousGeneration
        )
    }

    static let actionStages: [SpiceLiveAttemptStage] = [
        .preArm, .arm, .postArm,
    ]

    static func campaignPlan() throws -> SpiceLiveCampaignPlan {
        try SpiceLiveCampaignPlan(
            campaignID: "a10000000000000f",
            baselineVersion: "v0.2.7",
            candidateVersion: "v0.3.4",
            clusterIDs: (0..<10).map { String(format: "%016x", $0) }
        )
    }

    static func campaignMetadata() throws -> SpiceLiveCampaignManifestMetadata {
        try SpiceLiveCampaignManifestMetadata(
            baselineSourceCommit: String(repeating: "a", count: 40),
            candidateSourceCommit: String(repeating: "b", count: 40),
            toolchain: "Swift 6.3 / Xcode 27 beta",
            hardware: "Apple Silicon test host",
            thermalState: .nominal,
            workload: "aip-00-paired-click-key-motion-v1",
            startedAtUTC: "2026-08-31T00:00:00Z"
        )
    }

    static func campaignExecutionContract(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata
    ) throws -> SpiceLiveCampaignExecutionContract {
        try SpiceLiveCampaignExecutionContract(
            plan: plan,
            metadata: metadata,
            baselineVersion: plan.baselineVersion,
            candidateVersion: plan.candidateVersion,
            baselineSourceCommit: metadata.baselineSourceCommit,
            candidateSourceCommit: metadata.candidateSourceCommit,
            baselineReleaseBinarySHA256: String(repeating: "1", count: 64),
            candidateReleaseBinarySHA256: String(repeating: "2", count: 64),
            runnerSourceCommit: String(repeating: "c", count: 40),
            runnerReleaseBinarySHA256: String(repeating: "3", count: 64),
            remoteImageReference: "registry.example/swiftspice/perf:v0.3.4",
            remoteImageDigest: String(repeating: "4", count: 64),
            guestBuildManifestSHA256: String(repeating: "5", count: 64),
            fixtureSourcesSHA256: String(repeating: "6", count: 64),
            controlSourceSHA256: String(repeating: "7", count: 64),
            pointerMode: .absolute,
            stageProtocolVersion: .v1
        )
    }

    static func outputURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-aip00h2b2-driver-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appending(path: "campaign-manifest.json")
    }

    static func removeOutput(_ output: URL) {
        try? FileManager.default.removeItem(
            at: output.deletingLastPathComponent()
        )
    }

    static func canonicalManifestData(
        _ manifest: SpiceLiveCampaignManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
}
