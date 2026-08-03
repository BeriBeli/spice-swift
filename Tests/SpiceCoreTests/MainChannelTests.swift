import Foundation
import SpiceTestSupport
import SpiceTransport
import Synchronization
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Main Channel bootstrap")
struct MainChannelTests {
    @Test func requestsSupportedClientMouseModeWithoutAssumingAcceptance() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 1,
                agentConnected: 0,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        let bootstrap = try await channel.bootstrap()

        #expect(bootstrap.supportedMouseModes == 3)
        #expect(bootstrap.currentMouseMode == 1)
        let outbound = await transport.outbound
        #expect(try outbound.map(decodeMiniMessageID) == [105, 104])
        #expect(try decodeMiniBody(outbound[0]) == Data([0x02, 0x00]))
    }

    @Test func preservesServerModeWhenClientMouseModeIsUnsupported() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 1,
                currentMouseMode: 1,
                agentConnected: 0,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        let bootstrap = try await channel.bootstrap()

        #expect(bootstrap.supportedMouseModes == 1)
        #expect(bootstrap.currentMouseMode == 1)
        #expect(try (await transport.outbound).map(decodeMiniMessageID) == [104])
    }

    @Test func appliesMouseModeConfirmationReceivedDuringBootstrap() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 1,
                agentConnected: 0,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainMouseMode(
                supportedModes: 3,
                currentMode: 2
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        let bootstrap = try await channel.bootstrap()

        #expect(bootstrap.supportedMouseModes == 3)
        #expect(bootstrap.currentMouseMode == 2)
        let outbound = await transport.outbound
        #expect(try outbound.map(decodeMiniMessageID) == [105, 104])
        #expect(try decodeMiniBody(outbound[0]) == Data([0x02, 0x00]))
    }

    @Test func discoversChannelsAndHandlesPingAndAckWindow() async throws {
        let mainInit = SpiceMsgMainInit(
            sessionID: 42,
            displayChannelsHint: 1,
            supportedMouseModes: 3,
            currentMouseMode: 2,
            agentConnected: 0,
            agentTokens: 0,
            multimediaTime: 100,
            ramHint: 64 * 1024 * 1024
        )
        let channels = SpiceMsgMainChannelsList(channels: [
            SpiceChannelID(type: 2, id: 0),
            SpiceChannelID(type: 3, id: 0),
            SpiceChannelID(type: 4, id: 0),
        ])
        let inbound = try [
            encodeMiniServerMessage(mainInit),
            encodeMiniServerMessage(SpiceMsgSetAck(generation: 7, window: 2)),
            encodeMiniServerMessage(SpiceMsgPing(id: 9, time: 123_456)),
            encodeMiniServerMessage(channels),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        )

        let result = try await MainChannel(connection: connection).bootstrap()
        #expect(result.sessionID == 42)
        #expect(result.currentMouseMode == 2)
        #expect(result.channels == [
            ChannelDescriptor(type: 2, id: 0),
            ChannelDescriptor(type: 3, id: 0),
            ChannelDescriptor(type: 4, id: 0),
        ])

        let outbound = await transport.outbound
        #expect(outbound.count == 4)
        #expect(try decodeMiniMessageID(outbound[0]) == 104)
        #expect(try decodeMiniMessageID(outbound[1]) == 1)
        #expect(try decodeMiniMessageID(outbound[2]) == 3)
        #expect(try decodeMiniMessageID(outbound[3]) == 2)
    }

    @Test func rejectsAnyMessageBeforeMainInit() async throws {
        let inbound = try encodeMiniServerMessage(SpiceMsgPing(id: 1, time: 2))
        let transport = FakeTransport(inbound: [.success(inbound)])
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        )

        await #expect(throws: ChannelError.protocolViolation(
            "Main Init must be the first Main Channel message"
        )) {
            try await MainChannel(connection: connection).bootstrap()
        }
    }

    @Test func startsConnectedAgentAndSpendsClientTokensAtomically() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 2,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        let bootstrap = try await channel.bootstrap()
        #expect(bootstrap.agentConnected)
        try await channel.sendAgentMessage(VDAgentMessage(
            type: 6,
            data: Data(repeating: 0xa5, count: 3_000)
        ))
        #expect(try await channel.sendAgentMessageIfTokensAvailable(
            VDAgentMessage(type: 3, data: Data())
        ) == false)

        let outbound = await transport.outbound
        #expect(try outbound.map(decodeMiniMessageID) == [106, 104, 107, 107])
        #expect(try decodeMiniBody(outbound[0]) == uint32(8))
        #expect(try decodeMiniBody(outbound[2]).count == 2_048)
        #expect(try decodeMiniBody(outbound[3]).count == 972)
    }

    @Test func reservesTokenBeforeSuspendingTransportWrite() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 1,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = BlockingAgentWriteTransport(
            inbound: inbound.map(Result.success)
        )
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()
        await transport.setBlocksAgentWrites(true)

        let first = Task {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([1])))
        }
        #expect(await eventually { await transport.blockedAgentWriteCount == 1 })

        #expect(try await channel.sendAgentMessageIfTokensAvailable(
            VDAgentMessage(type: 3, data: Data([2]))
        ) == false)

        await transport.releaseAgentWrites()
        try await first.value
        #expect(await transport.agentWriteCount == 1)
    }

    @Test func cancellationBeforeFirstFragmentRemovesWireOwnership() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            agentClock: ManualAgentOutboundClock()
        )
        _ = try await channel.bootstrap()

        let send = Task {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([1])))
        }
        #expect(await eventually { await channel.pendingAgentMessageCount() == 1 })
        send.cancel()
        await #expect(throws: ChannelError.agentCancelled(partial: false)) {
            try await send.value
        }
        #expect(await channel.pendingAgentMessageCount() == 0)
        #expect(await transport.agentWriteCount == 0)
    }

    @Test func cancellationAfterWriteStartsDetachesCallerAndFinishesMessage() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 2,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = BlockingAgentWriteTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()
        await transport.setBlocksAgentWrites(true)

        let send = Task {
            try await channel.sendAgentMessage(VDAgentMessage(
                type: 3,
                data: Data(repeating: 0xa5, count: 3_000)
            ))
        }
        #expect(await eventually { await transport.blockedAgentWriteCount == 1 })
        send.cancel()
        await #expect(throws: ChannelError.agentCancelled(partial: true)) {
            try await send.value
        }

        await transport.releaseAgentWrites()
        #expect(await eventually { await transport.agentWriteCount == 2 })
        #expect(await eventually { await channel.pendingAgentMessageCount() == 0 })
        #expect(await transport.isClosed == false)
    }

    @Test func hardMessageBoundRejectsNinthBeforeRetainingPayload() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            agentClock: ManualAgentOutboundClock()
        )
        _ = try await channel.bootstrap()

        let accepted = (0..<8).map { value in
            Task {
                try await channel.sendAgentMessage(VDAgentMessage(
                    type: 3,
                    data: Data([UInt8(value)])
                ))
            }
        }
        #expect(await eventually { await channel.pendingAgentMessageCount() == 8 })
        await #expect(throws: ChannelError.agentQueueFull) {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([9])))
        }
        #expect(await channel.pendingAgentMessageCount() == 8)
        for task in accepted { task.cancel() }
        for task in accepted {
            await #expect(throws: ChannelError.agentCancelled(partial: false)) {
                try await task.value
            }
        }
    }

    @Test func writeFailureClassifiesBeforeFirstAndAfterPartial() async throws {
        for (failureAttempt, expectedPartial) in [(1, false), (2, true)] {
            let inbound = try [
                encodeMiniServerMessage(SpiceMsgMainInit(
                    sessionID: 42,
                    displayChannelsHint: 0,
                    supportedMouseModes: 3,
                    currentMouseMode: 2,
                    agentConnected: 1,
                    agentTokens: 2,
                    multimediaTime: 100,
                    ramHint: 0
                )),
                encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
            ]
            let transport = BlockingAgentWriteTransport(
                inbound: inbound.map(Result.success),
                failingAgentWriteAttempt: failureAttempt
            )
            try await transport.connect()
            let channel = MainChannel(connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ))
            _ = try await channel.bootstrap()

            await #expect(throws: ChannelError.agentMessageFailed(
                partial: expectedPartial
            )) {
                try await channel.sendAgentMessage(VDAgentMessage(
                    type: 3,
                    data: Data(repeating: 0xa5, count: 3_000)
                ))
            }
            #expect(await transport.isClosed)
        }
    }

    @Test func abortedMigrationPreparationRestoresSourceAdmission() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 1,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()

        try await channel.prepareAgentForMigrationRebind()
        await #expect(throws: ChannelError.agentMigrationRebind(partial: false)) {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([1])))
        }
        await channel.abortAgentMigrationRebind()
        try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([2])))
        #expect(await transport.agentWriteCount == 1)
    }

    @Test func migrationDeadlinePoisonsPartialGenerationAfterThreeSeconds() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 1,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = BlockingAgentWriteTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let clock = ManualAgentOutboundClock()
        let channel = MainChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            agentClock: clock
        )
        _ = try await channel.bootstrap()
        await transport.setBlocksAgentWrites(true)

        let send = Task {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([1])))
        }
        #expect(await eventually { await transport.blockedAgentWriteCount == 1 })
        let migration = Task {
            try await channel.prepareAgentForMigrationRebind()
        }
        #expect(await eventually { await clock.waiterCount >= 2 })
        await clock.fire(duration: .seconds(3))

        await #expect(throws: ChannelError.agentMigrationRebind(partial: true)) {
            try await migration.value
        }
        await #expect(throws: ChannelError.agentMigrationRebind(partial: true)) {
            try await send.value
        }
        #expect(await transport.isClosed)
    }

    @Test func migrationDrainsStartedMessageAndRejectsQueuedOwner() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 3,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let source = BlockingAgentWriteTransport(inbound: inbound.map(Result.success))
        try await source.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: source,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()
        await source.setBlocksAgentWrites(true)

        let active = Task {
            try await channel.sendAgentMessage(VDAgentMessage(
                type: 3,
                data: Data(repeating: 0xa5, count: 3_000)
            ))
        }
        #expect(await eventually { await source.blockedAgentWriteCount == 1 })
        let queued = Task {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([2])))
        }
        #expect(await eventually { await channel.pendingAgentMessageCount() == 2 })
        let migration = Task {
            try await channel.prepareAgentForMigrationRebind()
        }
        await #expect(throws: ChannelError.agentMigrationRebind(partial: false)) {
            try await queued.value
        }

        await source.releaseAgentWrites()
        try await active.value
        try await migration.value

        let target = FakeTransport()
        try await target.connect()
        _ = try await channel.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: target,
            headerMode: .mini
        ))
        try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([3])))
        #expect(await target.agentWriteCount == 1)
    }

    @Test func migrationRollbackPreservesSourceAgentTokensAndPartialDecoder() async throws {
        let message = VDAgentMessage(
            type: VDAgentMessageType.clipboard.rawValue,
            data: Data(repeating: 0xa5, count: 3_000)
        )
        let fragments = try VDAgentWireEncoder.fragments(for: message)
        #expect(fragments.count == 2)
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 1,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
            encodeMiniServerMessage(id: SpiceMainAgentWire.serverData, body: fragments[0]),
            encodeMiniServerMessage(id: 1, body: uint32(1)),
            encodeMiniServerMessage(id: SpiceMainAgentWire.serverData, body: fragments[1]),
        ]
        let source = FakeTransport(inbound: inbound.map(Result.success))
        try await source.connect()
        let sourceConnection = ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: source,
            headerMode: .mini
        )
        let channel = MainChannel(connection: sourceConnection)
        _ = try await channel.bootstrap()

        do {
            try await channel.run { _ in }
            Issue.record("source did not stop at its migration boundary")
        } catch let error {
            guard case .migrationRequested = error else {
                Issue.record("unexpected source error: \(error)")
                return
            }
        }

        try await channel.prepareAgentForMigrationRebind()
        let target = FakeTransport()
        try await target.connect()
        _ = try await channel.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: target,
            headerMode: .mini
        ))
        _ = try await channel.replaceConnection(with: sourceConnection)
        await sourceConnection.resumeAfterMigrationCancellation()

        let received = Mutex<[VDAgentMessage]>([])
        do {
            try await channel.run { event in
                if case let .main(.agentMessage(message)) = event {
                    received.withLock { $0.append(message) }
                }
            }
        } catch let error {
            guard error == .transport(.connectionClosed) else {
                Issue.record("unexpected resumed-source error: \(error)")
                return
            }
        }
        #expect(received.withLock { $0 } == [message])

        try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([7])))
        #expect(await source.agentWriteCount == 1)
        #expect(await target.agentWriteCount == 0)
    }

    @Test func reconnectDuringOutstandingOldGenerationWriteFailsClosed() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 1,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
            encodeMiniServerMessage(id: SpiceMainAgentWire.serverDisconnected, body: uint32(9)),
            encodeMiniServerMessage(id: SpiceMainAgentWire.serverConnectedTokens, body: uint32(1)),
        ]
        let transport = BlockingAgentWriteTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()
        await transport.setBlocksAgentWrites(true)

        let send = Task {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([1])))
        }
        #expect(await eventually { await transport.blockedAgentWriteCount == 1 })
        await #expect(throws: ChannelError.protocolViolation(
            "agent reconnected while a previous generation write was still in flight"
        )) {
            try await channel.run { _ in }
        }
        await #expect(throws: ChannelError.agentDisconnected) {
            try await send.value
        }
        await channel.close()
        #expect(await transport.isClosed)
    }

    @Test func replenishedTokenResumesSameLogicalMessage() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 1,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
            encodeMiniServerMessage(id: 110, body: uint32(1)),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let clock = ManualAgentOutboundClock()
        let channel = MainChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            agentClock: clock
        )
        _ = try await channel.bootstrap()

        let send = Task {
            try await channel.sendAgentMessage(VDAgentMessage(
                type: 6,
                data: Data(repeating: 0xa5, count: 3_000)
            ))
        }
        #expect(await eventually { await transport.agentWriteCount == 1 })

        let run = Task {
            try await channel.run { _ in }
        }
        try await send.value
        _ = try? await run.value
        #expect(await transport.agentWriteCount == 2)
    }

    @Test func partialNoProgressPoisonsGenerationAndFailsEveryWaiter() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 1,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let clock = ManualAgentOutboundClock()
        let channel = MainChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            agentClock: clock
        )
        _ = try await channel.bootstrap()

        let partial = Task {
            try await channel.sendAgentMessage(VDAgentMessage(
                type: 6,
                data: Data(repeating: 0xa5, count: 3_000)
            ))
        }
        #expect(await eventually { await transport.agentWriteCount == 1 })
        let queued = Task {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([2])))
        }
        #expect(await eventually { await channel.pendingAgentMessageCount() == 2 })
        #expect(await eventually { await clock.waiterCount > 0 })

        await clock.fireAll()

        await #expect(throws: ChannelError.agentStalled(partial: true)) {
            try await partial.value
        }
        await #expect(throws: ChannelError.agentStalled(partial: false)) {
            try await queued.value
        }
        #expect(await transport.isClosed)
        #expect(await transport.agentWriteCount == 1)
        await #expect(throws: ChannelError.agentDisconnected) {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([3])))
        }
    }

    @Test func noProgressBeforeFirstFragmentAlsoPoisonsAndFailsEveryWaiter() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let clock = ManualAgentOutboundClock()
        let channel = MainChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            agentClock: clock
        )
        _ = try await channel.bootstrap()

        let active = Task {
            try await channel.sendAgentMessage(VDAgentMessage(type: 6, data: Data([1])))
        }
        let queued = Task {
            try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([2])))
        }
        #expect(await eventually { await channel.pendingAgentMessageCount() == 2 })
        #expect(await eventually { await clock.waiterCount > 0 })
        #expect(await transport.agentWriteCount == 0)

        await clock.fireAll()

        await #expect(throws: ChannelError.agentStalled(partial: false)) {
            try await active.value
        }
        await #expect(throws: ChannelError.agentStalled(partial: false)) {
            try await queued.value
        }
        #expect(await transport.isClosed)
        #expect(await transport.agentWriteCount == 0)
    }

    @Test func rebindingPreservesAgentConnectionAndTokenState() async throws {
        let source = FakeTransport(inbound: try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 1,
                agentTokens: 2,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
        ].map(Result.success))
        try await source.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: source,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()
        try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([1])))

        let target = FakeTransport()
        try await target.connect()
        _ = try await channel.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: target,
            headerMode: .mini
        ))
        try await channel.sendAgentMessage(VDAgentMessage(type: 3, data: Data([2])))

        #expect(try (await target.outbound).map(decodeMiniMessageID) == [107])
        #expect(try await channel.sendAgentMessageIfTokensAvailable(
            VDAgentMessage(type: 3, data: Data([3]))
        ) == false)
    }

    @Test func reassemblesRuntimeAgentStreamAndReplenishesEveryPacket() async throws {
        let agentMessage = VDAgentMessage(
            protocolID: 1,
            type: 6,
            opaque: 9,
            data: Data("caps".utf8)
        )
        let encoded = try #require(VDAgentWireEncoder.fragments(for: agentMessage).first)
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 0,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
            encodeMiniServerMessage(id: 115, body: uint32(4)),
            encodeMiniServerMessage(id: 109, body: encoded.prefixData(8)),
            encodeMiniServerMessage(id: 109, body: encoded.suffixData(from: 8)),
            encodeMiniServerMessage(id: 108, body: uint32(7)),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()
        let collector = MainEventCollector()

        await #expect(throws: ChannelError.transport(.connectionClosed)) {
            try await channel.run { event in
                if case let .main(mainEvent) = event {
                    await collector.append(mainEvent)
                }
            }
        }

        #expect(await collector.events == [
            .agentConnected,
            .agentMessage(agentMessage),
            .agentDisconnected(errorCode: 7),
        ])
        let outbound = await transport.outbound
        #expect(try outbound.map(decodeMiniMessageID) == [104, 106, 108, 108])
        #expect(try decodeMiniBody(outbound[1]) == uint32(8))
        #expect(try decodeMiniBody(outbound[2]) == uint32(1))
        #expect(try decodeMiniBody(outbound[3]) == uint32(1))
    }

    @Test func rejectsAgentDataWhileDisconnected() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 0,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
            encodeMiniServerMessage(id: 109, body: Data()),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()

        await #expect(throws: ChannelError.protocolViolation(
            "agent data received while agent is disconnected"
        )) {
            try await channel.run { _ in }
        }
    }

    @Test func boundsAgentEventsAccumulatedBeforeChannelsList() async throws {
        let packet = try #require(VDAgentWireEncoder.fragments(
            for: VDAgentMessage(type: 3, data: Data())
        ).first)
        var inbound = try [encodeMiniServerMessage(SpiceMsgMainInit(
            sessionID: 42,
            displayChannelsHint: 0,
            supportedMouseModes: 3,
            currentMouseMode: 2,
            agentConnected: 1,
            agentTokens: 0,
            multimediaTime: 100,
            ramHint: 0
        ))]
        inbound.append(contentsOf: (0..<65).map { _ in
            encodeMiniServerMessage(id: 109, body: packet)
        })
        inbound.append(try encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])))
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        await #expect(throws: ChannelError.protocolViolation(
            "too many Agent events before delivery"
        )) {
            try await channel.bootstrap()
        }
    }

    @Test func seedsAndResetsSharedMultimediaClockAtRuntime() async throws {
        let clock = RecordingMultimediaClock(initialTime: 0)
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 1,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 0,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
            encodeMiniServerMessage(SpiceMsgMainMultimediaTime(multimediaTime: 250)),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            multimediaClock: clock
        )

        let bootstrap = try await channel.bootstrap()
        #expect(bootstrap.multimediaTime == 100)
        #expect(await clock.resetTimes == [100])
        await #expect(throws: ChannelError.transport(.connectionClosed)) {
            try await channel.run { _ in }
        }
        #expect(await clock.resetTimes == [100, 250])
    }

    @Test func publishesMigrationBeginAndSendsConnectErrorReply() async throws {
        let destination = SpiceMigrationDestination(
            host: "target.example",
            port: 5_900,
            securePort: 0,
            certificateSubject: nil
        )
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 0,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(SpiceMsgMainChannelsList(channels: [])),
            encodeMiniServerMessage(id: 101, body: migrationDestinationBody(
                host: "target.example"
            )),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.bootstrap()
        let collector = MainEventCollector()

        await #expect(throws: ChannelError.transport(.connectionClosed)) {
            try await channel.run { event in
                guard case let .main(mainEvent) = event else { return }
                await collector.append(mainEvent)
                if case .migration = mainEvent {
                    try? await channel.sendMigrationReply(.connectError)
                }
            }
        }

        #expect(await collector.events == [.migration(.begin(destination))])
        let outbound = await transport.outbound
        #expect(try outbound.map(decodeMiniMessageID) == [104, 103])
        #expect(try decodeMiniBody(outbound[1]).isEmpty)
    }

    @Test func rejectsMigrationBeforeChannelsList() async throws {
        let inbound = try [
            encodeMiniServerMessage(SpiceMsgMainInit(
                sessionID: 42,
                displayChannelsHint: 0,
                supportedMouseModes: 3,
                currentMouseMode: 2,
                agentConnected: 0,
                agentTokens: 0,
                multimediaTime: 100,
                ramHint: 0
            )),
            encodeMiniServerMessage(id: 101, body: migrationDestinationBody(host: "target")),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        await #expect(throws: ChannelError.protocolViolation(
            "migration control received before Main bootstrap completed"
        )) {
            try await channel.bootstrap()
        }
    }

    @Test func negotiatesDestinationSeamlessAckAndNackBeforeBootstrap() async throws {
        for (replyID, expected) in [(UInt16(117), true), (UInt16(118), false)] {
            let transport = FakeTransport(inbound: [
                .success(encodeMiniServerMessage(id: replyID, body: Data())),
            ])
            try await transport.connect()
            let channel = MainChannel(connection: ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: .mini
            ))

            #expect(try await channel.negotiateDestinationSeamless(
                sourceVersion: 9
            ) == expected)
            let outbound = await transport.outbound
            #expect(outbound.count == 1)
            #expect(try decodeMiniMessageID(outbound[0]) == 110)
            #expect(try decodeMiniBody(outbound[0]) == uint32(9))
        }
    }

    @Test func destinationSeamlessNegotiationRejectsUnrelatedMessage() async throws {
        let transport = FakeTransport(inbound: [
            .success(try encodeMiniServerMessage(
                SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 2)
            )),
        ])
        try await transport.connect()
        let channel = MainChannel(connection: ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        await #expect(throws: ChannelError.protocolViolation(
            "destination seamless negotiation expected ACK or NACK"
        )) {
            try await channel.negotiateDestinationSeamless(sourceVersion: 9)
        }
    }

    private func encodeMiniServerMessage<Message: SpiceGeneratedMessage>(
        _ message: Message
    ) throws -> Data {
        let id = try #require(Message.messageID)
        var bodyWriter = ByteWriter()
        try message.encode(to: &bodyWriter)
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(bodyWriter.data.count))
        writer.writeBytes(bodyWriter.data)
        return writer.data
    }

    private func encodeMiniServerMessage(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }

    private func decodeMiniMessageID(_ data: Data) throws -> UInt16 {
        var reader = try ByteReader(data)
        return try reader.readUInt16LE()
    }

    private func decodeMiniBody(_ data: Data) throws -> Data {
        var reader = try ByteReader(data)
        _ = try reader.readUInt16LE()
        let size = try reader.readUInt32LE()
        let body = try reader.readBytes(count: Int(size))
        try reader.requireFullyConsumed()
        return body
    }

    private func uint32(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }

    private func migrationDestinationBody(host: String) -> Data {
        let hostBytes = Data((host + "\0").utf8)
        var writer = ByteWriter()
        writer.writeUInt16LE(5_900)
        writer.writeUInt16LE(0)
        writer.writeUInt32LE(UInt32(hostBytes.count))
        writer.writeBytes(hostBytes)
        writer.writeUInt32LE(0)
        return writer.data
    }
}

private actor MainEventCollector {
    private(set) var events: [MainEvent] = []

    func append(_ event: MainEvent) {
        events.append(event)
    }
}

private func eventually(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private actor ManualAgentOutboundClock: AgentOutboundClock {
    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var nextID: UInt64 = 1
    private var waiters: [UInt64: Waiter] = [:]

    var waiterCount: Int {
        waiters.count
    }

    func sleep(for duration: Duration) async throws {
        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(
                    duration: duration,
                    continuation: continuation
                )
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func fireAll() {
        let current = waiters.values.map(\.continuation)
        waiters.removeAll(keepingCapacity: false)
        for waiter in current {
            waiter.resume()
        }
    }

    func fire(duration: Duration) {
        let ids = waiters.compactMap { id, waiter in
            waiter.duration == duration ? id : nil
        }
        let current = ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        for waiter in current {
            waiter.resume()
        }
    }

    private func cancel(id: UInt64) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

private actor BlockingAgentWriteTransport: SpiceTransport {
    private var inbound: [Result<Data, TransportError>]
    private var outbound: [Data] = []
    private var blocksAgentWrites = false
    private let failingAgentWriteAttempt: Int?
    private var agentWriteAttempts = 0
    private var writeWaiters: [CheckedContinuation<Void, Error>] = []
    private(set) var blockedAgentWriteCount = 0
    private(set) var isConnected = false
    private(set) var isClosed = false

    init(
        inbound: [Result<Data, TransportError>],
        failingAgentWriteAttempt: Int? = nil
    ) {
        self.inbound = inbound
        self.failingAgentWriteAttempt = failingAgentWriteAttempt
    }

    var agentWriteCount: Int {
        outbound.filter(Self.isAgentData).count
    }

    func connect() async throws(TransportError) {
        guard !isClosed else { throw .connectionClosed }
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard isConnected, !isClosed else { throw .connectionClosed }
        guard minimum >= 0, maximum >= minimum else {
            throw .connectionFailed("invalid read bounds")
        }
        guard !inbound.isEmpty else { throw .connectionClosed }
        let data = try inbound.removeFirst().get()
        guard data.count <= maximum else {
            throw .connectionFailed("fixture exceeds requested maximum")
        }
        return data
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected, !isClosed else { throw .connectionClosed }
        let payload = data
        if Self.isAgentData(payload) {
            agentWriteAttempts += 1
            if agentWriteAttempts == failingAgentWriteAttempt {
                throw .connectionFailed("injected Agent write failure")
            }
        }
        if blocksAgentWrites, Self.isAgentData(payload) {
            blockedAgentWriteCount += 1
            do {
                try await withCheckedThrowingContinuation { continuation in
                    writeWaiters.append(continuation)
                }
            } catch is CancellationError {
                throw .cancelled
            } catch let error as TransportError {
                throw error
            } catch {
                throw .connectionFailed(String(describing: error))
            }
        }
        guard isConnected, !isClosed else { throw .connectionClosed }
        outbound.append(payload)
    }

    func close() async {
        isClosed = true
        isConnected = false
        let waiters = writeWaiters
        writeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: TransportError.connectionClosed)
        }
    }

    func setBlocksAgentWrites(_ enabled: Bool) {
        blocksAgentWrites = enabled
    }

    func releaseAgentWrites() {
        blocksAgentWrites = false
        let waiters = writeWaiters
        writeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private nonisolated static func isAgentData(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 107 && data[data.startIndex + 1] == 0
    }
}

private extension FakeTransport {
    var agentWriteCount: Int {
        outbound.filter { data in
            data.count >= 2 && data[data.startIndex] == 107 && data[data.startIndex + 1] == 0
        }.count
    }
}

private extension Data {
    func prefixData(_ count: Int) -> Data {
        Data(prefix(count))
    }

    func suffixData(from offset: Int) -> Data {
        Data(dropFirst(offset))
    }
}

private actor RecordingMultimediaClock: MultimediaClockScheduling {
    private var currentTime: UInt32
    private(set) var resetTimes: [UInt32] = []

    init(initialTime: UInt32) {
        currentTime = initialTime
    }

    func reset(to multimediaTime: UInt32) {
        currentTime = multimediaTime
        resetTimes.append(multimediaTime)
    }

    func synchronize(playbackTime: UInt32, delayMilliseconds: UInt32) {
        currentTime = playbackTime &- delayMilliseconds
    }

    func timing(for multimediaTime: UInt32) -> MultimediaFrameTiming {
        MultimediaTimestamp.timing(current: currentTime, target: multimediaTime)
    }

    func wait(until multimediaTime: UInt32) -> MultimediaFrameTiming {
        let result = timing(for: multimediaTime)
        if case .early = result {
            currentTime = multimediaTime
            return .due
        }
        return result
    }
}
