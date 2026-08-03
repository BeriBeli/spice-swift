import Foundation
import SpiceTestSupport
import SpiceTransport
import Synchronization
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire
@testable import SwiftSpice

@Suite("SpiceSession bootstrap")
struct SpiceSessionTests {
    @Test func requestsClientMouseModeAndPublishesServerDecisions() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            supportedMouseModes: 3,
            currentMouseMode: 1
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )

        let info = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        #expect(info.supportedMouseModes == 3)
        #expect(info.currentMouseMode == 1)
        await transport.waitForOutboundCount(5)
        let outbound = await transport.outbound
        #expect(try decodeMiniMessageID(outbound[3]) == 105)
        #expect(try decodeMiniBody(outbound[3]) == Data([0x02, 0x00]))
        #expect(try decodeMiniMessageID(outbound[4]) == 104)

        var events = session.events.makeAsyncIterator()
        await transport.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 2)
        ))
        #expect(await events.next() == .mouseMode(supported: 3, current: 2))

        await transport.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 1)
        ))
        #expect(await events.next() == .mouseMode(supported: 3, current: 1))
        await session.disconnect()
    }

    @Test func supervisesExplicitNativeWebDAVServer() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [SpiceChannelID(type: 11, id: 0)]
        ))
        let webDAV = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, webDAV])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spice-session-webdav-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("native".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await session.attachWebDAVServer(try SpiceWebDAVServer(root: root))

        let portName = Data("org.spice-space.webdav.0\0".utf8)
        var initialization = ByteWriter()
        initialization.writeUInt32LE(UInt32(portName.count))
        initialization.writeUInt32LE(9)
        initialization.writeUInt8(1)
        initialization.writeBytes(portName)
        await webDAV.enqueue(encodeMini(id: 201, body: initialization.data))
        let request = Data("GET /file.txt HTTP/1.1\r\nHost: fixture.invalid\r\n\r\n".utf8)
        await webDAV.enqueue(encodeMini(
            id: 101,
            body: try SpiceWebDAVMuxEncoder().encode(clientID: 27, data: request)
        ))

        await webDAV.waitForOutboundCount(4)
        var mux = SpiceWebDAVMuxDecoder()
        let frames = try mux.append(decodeMiniBody(
            try #require((await webDAV.outbound).last)
        ))
        let response = try #require(frames.first)
        #expect(response.clientID == 27)
        #expect(String(decoding: response.data, as: UTF8.self).contains("200 OK"))
        #expect(response.data.suffix(6) == Data("native".utf8))
        await session.disconnect()
    }

    @Test func supervisesWebDAVMuxWithoutImplicitFilesystemAccess() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [SpiceChannelID(type: 11, id: 0)]
        ))
        let webDAV = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, webDAV])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.webDAVEvents.makeAsyncIterator()

        let portName = Data("org.spice-space.webdav.0\0".utf8)
        var initialization = ByteWriter()
        initialization.writeUInt32LE(UInt32(portName.count))
        initialization.writeUInt32LE(9)
        initialization.writeUInt8(1)
        initialization.writeBytes(portName)
        await webDAV.enqueue(encodeMini(id: 201, body: initialization.data))
        #expect(await events.next() == .initialized(
            name: "org.spice-space.webdav.0",
            opened: true
        ))

        let request = Data("OPTIONS / HTTP/1.1\r\n\r\n".utf8)
        await webDAV.enqueue(encodeMini(
            id: 101,
            body: try SpiceWebDAVMuxEncoder().encode(clientID: 9, data: request)
        ))
        #expect(await events.next() == .request(clientID: 9, data: request))
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        try await session.sendWebDAVResponse(clientID: 9, data: response)
        await webDAV.waitForOutboundCount(4)
        var mux = SpiceWebDAVMuxDecoder()
        #expect(try mux.append(decodeMiniBody(
            try #require((await webDAV.outbound).last)
        )) == [SpiceWebDAVFrame(clientID: 9, data: response)])
        await session.disconnect()
    }

    @Test func supervisesExplicitUSBRedirectionPacketBridge() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [SpiceChannelID(type: 9, id: 3)]
        ))
        let usb = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, usb])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var packets = session.usbRedirectionPackets.makeAsyncIterator()

        await usb.enqueue(encodeMini(id: 101, body: Data([1, 2, 3])))
        #expect(await packets.next() == SpiceUSBRedirectionPacket(
            channelID: 3,
            data: Data([1, 2, 3])
        ))
        try await session.sendUSBRedirectionPacket(
            channelID: 3,
            data: Data([4, 5, 6])
        )
        await usb.waitForOutboundCount(4)
        #expect(try decodeMiniMessageID(try #require((await usb.outbound).last)) == 101)
        #expect(try decodeMiniBody(try #require((await usb.outbound).last)) == Data([4, 5, 6]))
        await session.disconnect()
    }

    @Test func supervisesExactUSBRedirectionHostWithoutAutomaticDeviceAccess() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [SpiceChannelID(type: 9, id: 0)]
        ))
        let usb = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, usb])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )

        let host = try SpiceUSBRedirectionHost()
        try await session.attachUSBRedirectionHost(host, channelID: 0)
        await usb.waitForOutboundCount(4)
        let hello = try decodeMiniBody(try #require((await usb.outbound).last))
        #expect(!hello.isEmpty)

        await #expect(throws: SpiceError.protocolError(
            "USB redirection backend: deviceNotFound"
        )) {
            try await session.attachUSBDevice(
                channelID: 0,
                busNumber: .max,
                deviceAddress: .max
            )
        }
        await session.disconnect()
        #expect(!(await usb.isConnected))
    }

    @Test func supervisesExplicitSmartcardLifecycleWithoutHostEnumeration() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [SpiceChannelID(type: 8, id: 0)]
        ))
        let smartcard = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, smartcard])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.smartcardEvents.makeAsyncIterator()

        try await session.addSmartcardReader(named: "Explicit Reader")
        await smartcard.waitForOutboundCount(4)
        let add = try SpiceSmartcardWireCodec().decode(
            try decodeMiniBody(try #require((await smartcard.outbound).last))
        )
        #expect(add.type == .readerAdd)
        #expect(add.readerID == .max)
        #expect(add.payload == Data("Explicit Reader".utf8))

        await smartcard.enqueue(encodeMini(
            id: 101,
            body: try SpiceSmartcardWireCodec().encode(SpiceSmartcardMessage(
                type: .error,
                readerID: 7,
                payload: uint32(0)
            ))
        ))
        #expect(await events.next() == .operationCompleted(
            request: .readerAdd,
            readerID: 7,
            errorCode: 0
        ))

        await smartcard.enqueue(encodeMini(
            id: 101,
            body: try SpiceSmartcardWireCodec().encode(SpiceSmartcardMessage(
                type: .apdu,
                readerID: 7,
                payload: Data([0, 0xa4, 4, 0])
            ))
        ))
        #expect(await events.next() == .apdu(
            readerID: 7,
            data: Data([0, 0xa4, 4, 0])
        ))
        try await session.respondToSmartcardAPDU(readerID: 7, data: Data([0x90, 0]))
        await smartcard.waitForOutboundCount(5)
        let response = try SpiceSmartcardWireCodec().decode(
            try decodeMiniBody(try #require((await smartcard.outbound).last))
        )
        #expect(response == SpiceSmartcardMessage(
            type: .apdu,
            readerID: 7,
            payload: Data([0x90, 0])
        ))

        await smartcard.enqueue(encodeMini(
            id: 101,
            body: try SpiceSmartcardWireCodec().encode(SpiceSmartcardMessage(
                type: .flush,
                readerID: 7
            ))
        ))
        #expect(await events.next() == .flushRequested(readerID: 7))
        try await session.completeSmartcardFlush(readerID: 7)
        await smartcard.waitForOutboundCount(6)
        let flush = try SpiceSmartcardWireCodec().decode(
            try decodeMiniBody(try #require((await smartcard.outbound).last))
        )
        #expect(flush.type == .flushComplete)
        await session.disconnect()
    }

    @Test func mapsPlaybackEventsAndRejectsDelayWithoutChannel() async throws {
        #expect(SpiceSession.playbackEvent(.modeChanged(
            multimediaTime: 10,
            mode: .raw
        )) == .modeChanged(multimediaTime: 10, mode: .raw))
        #expect(SpiceSession.playbackEvent(.started(SpiceProtocol.SpicePlaybackStart(
            channels: 2,
            format: .s16,
            frequency: 48_000,
            multimediaTime: 10
        ))) == .started(SpicePlaybackConfiguration(
            channels: 2,
            format: .signed16LittleEndian,
            sampleRate: 48_000
        )))
        #expect(SpiceSession.playbackEvent(.packet(SpiceProtocol.SpicePlaybackPacket(
            multimediaTime: 20,
            data: Data([1, 2, 3, 4])
        ))) == .packet(SpicePlaybackPacket(
            multimediaTime: 20,
            data: Data([1, 2, 3, 4])
        )))
        #expect(SpiceSession.playbackEvent(.ignored(4)) == nil)

        let session = SpiceSession()
        await #expect(throws: SpiceError.protocolError("Playback Channel is not connected")) {
            try await session.reportPlaybackDelay(milliseconds: 20)
        }
    }

    @Test func mapsRecordEventsAndRejectsCaptureWithoutChannel() async throws {
        #expect(SpiceSession.recordEvent(.started(SpiceRecordStart(
            channels: 1,
            format: .s16,
            frequency: 44_100
        ))) == .started(SpiceRecordConfiguration(
            channels: 1,
            format: .signed16LittleEndian,
            sampleRate: 44_100
        )))
        #expect(SpiceSession.recordEvent(.volumeChanged([100])) == .volumeChanged([100]))
        #expect(SpiceSession.recordEvent(.muteChanged(true)) == .muteChanged(true))
        #expect(SpiceSession.recordEvent(.ignored(4)) == nil)

        let session = SpiceSession()
        await #expect(throws: SpiceError.protocolError("Record Channel is not connected")) {
            try await session.beginRecording(timestamp: 1)
        }
        await #expect(throws: SpiceError.protocolError("Record Channel is not connected")) {
            try await session.sendRecordedAudio(timestamp: 1, pcm: Data([0, 0]))
        }
    }

    @Test func supervisesMainAfterBootstrapAndPublishesFailure() async throws {
        let mouseMode = SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 2)
        let mainTransport = FakeTransport(inbound: try makeServerTranscript(
            channels: [],
            trailing: [encodeMini(mouseMode)]
        ).map(Result.success))
        let transports = TransportPool([mainTransport])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        let eventTask = Task {
            var iterator = session.events.makeAsyncIterator()
            return [await iterator.next(), await iterator.next()]
        }

        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )

        let events = await eventTask.value
        #expect(events[0] == .mouseMode(supported: 3, current: 2))
        guard case .failed = events[1] else {
            Issue.record("expected supervised Main failure")
            return
        }
        #expect(await mainTransport.isClosed)
    }

    @Test func connectsDiscoversChannelsAndDisconnects() async throws {
        let mainTransport = FakeTransport(
            inbound: try makeServerTranscript().map(Result.success)
        )
        let displayTransport = FakeTransport(
            inbound: try makeLinkResponses().map(Result.success)
        )
        let inputsTransport = FakeTransport(
            inbound: try makeLinkResponses().map(Result.success)
        )
        let cursorTransport = FakeTransport(
            inbound: try makeLinkResponses().map(Result.success)
        )
        let transports = TransportPool([
            mainTransport,
            displayTransport,
            inputsTransport,
            cursorTransport,
        ])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        let credentials = SpiceCredentials(password: "secret")

        let info = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: credentials
        )
        #expect(info.sessionID == 77)
        #expect(!info.agentConnected)
        #expect(info.channels == [
            SpiceChannelDescriptor(type: 2, id: 0),
            SpiceChannelDescriptor(type: 3, id: 0),
            SpiceChannelDescriptor(type: 4, id: 0),
        ])

        await session.disconnect()
        #expect(await mainTransport.isClosed)
        #expect(await displayTransport.isClosed)
        #expect(await inputsTransport.isClosed)
        #expect(await cursorTransport.isClosed)

        let displayLink = try decodeLinkRequest(try #require(await displayTransport.outbound.first))
        #expect(displayLink.connectionID == 77)
        #expect(displayLink.channelType == 2)
        let inputsLink = try decodeLinkRequest(try #require(await inputsTransport.outbound.first))
        #expect(inputsLink.connectionID == 77)
        #expect(inputsLink.channelType == 3)
    }

    @Test func publishesAgentEventsOnDedicatedStream() async throws {
        let agentMessage = VDAgentMessage(
            protocolID: 1,
            type: 6,
            opaque: 11,
            data: Data("agent".utf8)
        )
        let encoded = try #require(VDAgentWireEncoder.fragments(for: agentMessage).first)
        var transcript = try makeServerTranscript(channels: [])
        transcript.append(encodeMini(id: 115, body: uint32(2)))
        transcript.append(encodeMini(id: 109, body: encoded))
        transcript.append(encodeMini(id: 108, body: uint32(9)))
        let transport = FakeTransport(inbound: transcript.map(Result.success))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        let eventTask = Task {
            var iterator = session.agentEvents.makeAsyncIterator()
            return [await iterator.next(), await iterator.next(), await iterator.next()]
        }

        let info = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        #expect(!info.agentConnected)
        #expect(await eventTask.value == [
            .connected,
            .message(SpiceAgentMessage(
                protocolID: 1,
                type: 6,
                opaque: 11,
                data: Data("agent".utf8)
            )),
            .disconnected(errorCode: 9),
        ])
    }

    @Test func publishesAgentConnectedStateFromMainInit() async throws {
        let transport = FakeTransport(inbound: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ).map(Result.success))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )

        let info = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var iterator = session.agentEvents.makeAsyncIterator()

        #expect(info.agentConnected)
        #expect(await iterator.next() == .connected)
    }

    @Test func agentManagerSendsResolutionAndPublishesReply() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        var events = manager.displayConfigurationEvents.makeAsyncIterator()

        try await manager.requestResolution(width: 1_440, height: 900)
        #expect(await events.next() == .queued(.init(width: 1_440, height: 900)))
        #expect(await events.next() == .sent(.init(width: 1_440, height: 900)))
        await transport.waitForOutboundCount(6)

        let outbound = await transport.outbound
        let agentPackets = try outbound.compactMap { packet -> Data? in
            guard packet.count >= 6, try decodeMiniMessageID(packet) == 107 else {
                return nil
            }
            return try decodeMiniBody(packet)
        }
        var decoder = VDAgentStreamDecoder()
        let messages = try agentPackets.flatMap { try decoder.append(packet: $0) }
        let monitorMessage = try #require(messages.last)
        #expect(monitorMessage.type == VDAgentMessageType.monitorsConfig.rawValue)
        #expect(monitorMessage.data.prefix(8) == uint32(1) + uint32(0))

        let reply = VDAgentMessage(
            type: VDAgentMessageType.reply.rawValue,
            data: uint32(VDAgentMessageType.monitorsConfig.rawValue) + uint32(1)
        )
        let replyPacket = try #require(VDAgentWireEncoder.fragments(for: reply).first)
        await transport.enqueue(encodeMini(id: 109, body: replyPacket))

        #expect(await events.next() == .acknowledged(.init(width: 1_440, height: 900)))
        await manager.stop()
        await session.disconnect()
    }

    @Test func clipboardDriverReentrancyDoesNotDuplicateInFlightAnnouncement() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 32
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        await transport.blockAgentMessages(types: [
            VDAgentMessageType.announceCapabilities.rawValue,
        ])
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        let start = Task {
            try await manager.start(session: session)
        }
        await transport.waitForBlockedAgentWriteCount(1)

        await manager.synchronizePasteboard()
        await manager.synchronizePasteboard()
        #expect(await transport.blockedAgentWriteCount == 1)

        await transport.releaseBlockedAgentWrites()
        try await start.value
        await manager.stop()
        let messages = try decodedAgentMessages(await transport.outbound)
        #expect(messages.filter {
            $0.type == VDAgentMessageType.announceCapabilities.rawValue
        }.count == 1)
        await session.disconnect()
    }

    @Test func stoppedInitialAnnouncementCannotResurrectManagerTasks() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 32
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        await transport.blockAgentMessages(types: [
            VDAgentMessageType.announceCapabilities.rawValue,
        ])
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        let staleStart = Task {
            try await manager.start(session: session)
        }
        await transport.waitForBlockedAgentWriteCount(1)

        let stopReturned = Mutex(false)
        let invalidationBaseline = await manager.agentWorkInvalidationSequenceForTesting()
        let stop = Task {
            await manager.stop()
            stopReturned.withLock { $0 = true }
        }
        await manager.waitUntilAgentWorkInvalidatesForTesting(after: invalidationBaseline)
        #expect(await manager.ownedAgentSendCountForTesting() == 1)
        #expect(!stopReturned.withLock { $0 })
        await #expect(throws: SpiceClipboardError.alreadyRunning) {
            try await manager.start(session: session)
        }

        await transport.releaseBlockedAgentWrites()
        await stop.value
        #expect(stopReturned.withLock { $0 })
        #expect(await manager.ownedAgentSendCountForTesting() == 0)
        await #expect(throws: SpiceClipboardError.transport(.cancelled)) {
            try await staleStart.value
        }

        // The stale start must not install event/poll tasks after stop; a fresh
        // lifecycle can start immediately instead of reporting alreadyRunning.
        try await manager.start(session: session)
        await manager.stop()
        #expect(await transport.agentWriteCount == 2)
        await session.disconnect()
    }

    @Test func stopRemovesZeroTokenClipboardOwnerBeforeFreshLifecycle() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 1
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        let stalePayload = Data("stale-zero-token".utf8)
        let staleSend = Task {
            await manager.sendClipboardCommandForTesting(.data(
                type: VDAgentClipboardType.utf8Text.rawValue,
                data: stalePayload
            ))
        }
        await waitForOwnedAgentSendCount(1, manager: manager)

        await manager.stop()
        #expect(await manager.ownedAgentSendCountForTesting() == 0)
        await staleSend.value

        let freshStart = Task { try await manager.start(session: session) }
        await waitForOwnedAgentSendCount(1, manager: manager)
        await transport.enqueue(encodeMini(id: 110, body: uint32(1)))
        try await freshStart.value

        let commands = try decodedAgentMessages(await transport.outbound).compactMap {
            try VDAgentClipboardCodec.decode($0)
        }
        #expect(!commands.contains(.data(
            type: VDAgentClipboardType.utf8Text.rawValue,
            data: stalePayload
        )))
        #expect(commands.filter {
            if case .announceCapabilities = $0 { return true }
            return false
        }.count == 2)
        await manager.stop()
        await session.disconnect()
    }

    @Test func stopRemovesZeroTokenFileStartBeforeFreshLifecycle() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 1
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        var clipboardEvents = manager.events.makeAsyncIterator()
        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        await transport.enqueue(encodeMini(
            id: 109,
            body: try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        ))
        #expect(await clipboardEvents.next() == .ready)

        let source = FileManager.default.temporaryDirectory.appending(
            path: "spice-swift-zero-token-\(UUID().uuidString).bin"
        )
        try Data([1, 2, 3]).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        let staleFile = Task {
            try await manager.sendFile(at: source, name: "stale.bin")
        }
        await waitForOwnedAgentSendCount(1, manager: manager)

        await manager.stop()
        #expect(await manager.ownedAgentSendCountForTesting() == 0)
        await #expect(throws: SpiceFileTransferError.agentUnavailable) {
            _ = try await staleFile.value
        }

        let freshStart = Task { try await manager.start(session: session) }
        await waitForOwnedAgentSendCount(1, manager: manager)
        await transport.enqueue(encodeMini(id: 110, body: uint32(1)))
        try await freshStart.value

        let fileCommands = try decodedAgentMessages(await transport.outbound).compactMap {
            try VDAgentFileTransferCodec().decode($0)
        }
        #expect(!fileCommands.contains(where: {
            if case .start = $0 { return true }
            return false
        }))
        await manager.stop()
        await session.disconnect()
    }

    @Test func clipboardOwnerWaitsForPartialCancelledWireCompletion() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 32
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        let agentWritesBeforeData = await transport.agentWriteCount
        await transport.blockAgentWrites(afterWrittenCount: agentWritesBeforeData + 1)
        let payload = Data(repeating: 0x61, count: 3_000)
        let finished = Mutex(false)
        let send = Task {
            await manager.sendClipboardCommandForTesting(.data(
                type: VDAgentClipboardType.utf8Text.rawValue,
                data: payload
            ))
            finished.withLock { $0 = true }
        }
        await transport.waitForBlockedAgentWriteCount(1)

        send.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished.withLock { $0 })
        await transport.releaseBlockedAgentWrites()
        await send.value
        #expect(finished.withLock { $0 })

        let commands = try decodedAgentMessages(await transport.outbound).compactMap {
            try VDAgentClipboardCodec.decode($0)
        }
        #expect(commands.filter {
            $0 == .data(type: VDAgentClipboardType.utf8Text.rawValue, data: payload)
        }.count == 1)
        await manager.stop()
        await session.disconnect()
    }

    @Test func monitorReplyAndNewQueueDuringSendKeepOneOwnerPerConfiguration() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 32
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        await transport.blockAgentMessages(types: [
            VDAgentMessageType.monitorsConfig.rawValue,
        ])
        var events = manager.displayConfigurationEvents.makeAsyncIterator()
        let first = SpiceDisplayConfiguration(width: 800, height: 600)
        let latest = SpiceDisplayConfiguration(width: 1_024, height: 768)

        let firstSend = Task {
            try await manager.requestDisplayConfiguration(first)
        }
        #expect(await events.next() == .queued(first))
        await transport.waitForBlockedAgentWriteCount(1)
        try await manager.requestDisplayConfiguration(latest)
        #expect(await events.next() == .queued(latest))

        let reply = VDAgentMessage(
            type: VDAgentMessageType.reply.rawValue,
            data: uint32(VDAgentMessageType.monitorsConfig.rawValue) + uint32(1)
        )
        await transport.enqueue(encodeMini(
            id: 109,
            body: try #require(VDAgentWireEncoder.fragments(for: reply).first)
        ))
        #expect(await events.next() == .acknowledged(first))
        #expect(await transport.blockedAgentWriteCount == 1)

        let outboundBeforeRelease = await transport.outbound.count
        await transport.releaseBlockedAgentWrites()
        try await firstSend.value
        await transport.waitForOutboundCount(outboundBeforeRelease + 2)
        let messages = try decodedAgentMessages(await transport.outbound)
        #expect(messages.filter {
            $0.type == VDAgentMessageType.monitorsConfig.rawValue
        }.count == 2)

        await manager.stop()
        await session.disconnect()
    }

    @Test func agentManagerEncodesSparsePositionedMonitorLayout() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        var supportEvents = manager.displayConfigurationSupportEvents.makeAsyncIterator()
        try await manager.start(session: session)
        var clipboardEvents = manager.events.makeAsyncIterator()

        #expect(await supportEvents.next() == SpiceDisplayConfigurationSupport(
            agentConnected: true,
            hasExplicitPeerCapabilities: false,
            supportsMonitorConfiguration: true,
            supportsSparseMonitors: false,
            supportsMonitorPositions: false
        ))

        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        let capabilityPacket = try #require(
            VDAgentWireEncoder.fragments(for: capabilities).first
        )
        await transport.enqueue(encodeMini(id: 109, body: capabilityPacket))
        #expect(await clipboardEvents.next() == .ready)
        #expect(await supportEvents.next() == SpiceDisplayConfigurationSupport(
            agentConnected: true,
            hasExplicitPeerCapabilities: true,
            supportsMonitorConfiguration: true,
            supportsSparseMonitors: true,
            supportsMonitorPositions: true
        ))

        let layout = SpiceDisplayConfiguration(monitors: [
            .init(id: 0, x: 0, y: 0, width: 1_920, height: 1_080),
            .init(id: 2, x: 1_920, y: 0, width: 1_280, height: 1_024),
        ])
        var displayEvents = manager.displayConfigurationEvents.makeAsyncIterator()
        try await manager.requestDisplayConfiguration(layout)
        #expect(await displayEvents.next() == .queued(layout))
        #expect(await displayEvents.next() == .sent(layout))

        let outbound = await transport.outbound
        let agentPackets = try outbound.compactMap { packet -> Data? in
            guard packet.count >= 6, try decodeMiniMessageID(packet) == 107 else {
                return nil
            }
            return try decodeMiniBody(packet)
        }
        var decoder = VDAgentStreamDecoder()
        let messages = try agentPackets.flatMap { try decoder.append(packet: $0) }
        let monitorMessage = try #require(messages.last(where: {
            $0.type == VDAgentMessageType.monitorsConfig.rawValue
        }))
        var reader = try ByteReader(monitorMessage.data)
        #expect(try reader.readUInt32LE() == 3)
        #expect(try reader.readUInt32LE() == 1)
        let first = try readAgentMonitor(from: &reader)
        let disabled = try readAgentMonitor(from: &reader)
        let third = try readAgentMonitor(from: &reader)
        #expect(first == [1_080, 1_920, 32, 0, 0])
        #expect(disabled == [0, 0, 32, 0, 0])
        #expect(third == [1_024, 1_280, 32, 1_920, 0])
        #expect(reader.remainingCount == 0)

        await manager.stop()
        await session.disconnect()
    }

    @Test func publishesGuestMonitorLayoutFromDisplayChannel() async throws {
        let mainTransport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [SpiceChannelID(type: 2, id: 3)]
        ))
        var monitorBody = ByteWriter()
        monitorBody.writeUInt16LE(2)
        monitorBody.writeUInt16LE(4)
        for values: [UInt32] in [
            [0, 10, 1_920, 1_080, 0, 0, 0],
            [1, 11, 1_280, 1_024, 1_920, 0, 0],
        ] {
            for value in values {
                monitorBody.writeUInt32LE(value)
            }
        }
        let displayTransport = FakeTransport(inbound: (
            try makeLinkResponses() + [encodeMini(id: 317, body: monitorBody.data)]
        ).map(Result.success))
        let transports = TransportPool([mainTransport, displayTransport])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        let eventTask = Task<SpiceGuestDisplayConfiguration?, Never> {
            for await event in session.events {
                if case let .displayConfiguration(configuration) = event {
                    return configuration
                }
            }
            return nil
        }

        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let configuration = try #require(await eventTask.value)
        #expect(configuration.channelID == 3)
        #expect(configuration.maximumAllowed == 4)
        #expect(configuration.monitors.map(\.id) == [0, 1])
        #expect(configuration.monitors[1].surfaceID == 11)
        #expect(configuration.monitors[1].x == 1_920)
        await session.disconnect()
    }

    @Test func agentManagerTransfersExplicitFileAfterGuestApproval() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        var clipboardEvents = manager.events.makeAsyncIterator()

        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        let capabilityPacket = try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        await transport.enqueue(encodeMini(id: 109, body: capabilityPacket))
        #expect(await clipboardEvents.next() == .ready)

        let bytes = Data([1, 2, 3, 4, 5])
        let source = FileManager.default.temporaryDirectory.appending(
            path: "spice-swift-transfer-\(UUID().uuidString).bin"
        )
        try bytes.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        var events = manager.fileTransferEvents.makeAsyncIterator()
        let id = try await manager.sendFile(at: source, name: "fixture.bin")
        #expect(await events.next() == .queued(
            id: id,
            name: "fixture.bin",
            totalBytes: UInt64(bytes.count)
        ))
        #expect(await events.next() == .awaitingGuestApproval(id: id))

        let codec = VDAgentFileTransferCodec()
        let canSend = codec.encodeStatus(id: id.rawValue, result: .canSendData)
        let canSendPacket = try #require(VDAgentWireEncoder.fragments(for: canSend).first)
        await transport.enqueue(encodeMini(id: 109, body: canSendPacket))
        #expect(await events.next() == .progress(
            id: id,
            sentBytes: UInt64(bytes.count),
            totalBytes: UInt64(bytes.count)
        ))

        let outbound = await transport.outbound
        let agentPackets = try outbound.compactMap { packet -> Data? in
            guard packet.count >= 6, try decodeMiniMessageID(packet) == 107 else {
                return nil
            }
            return try decodeMiniBody(packet)
        }
        var decoder = VDAgentStreamDecoder()
        let messages = try agentPackets.flatMap { try decoder.append(packet: $0) }
        let commands = try messages.compactMap { try codec.decode($0) }
        #expect(commands.contains(where: { command in
            guard case let .start(startID, metadata) = command else {
                return false
            }
            return startID == id.rawValue
                && metadata == Data(
                    "[vdagent-file-xfer]\nname=fixture.bin\nsize=5\n\0".utf8
                )
        }))
        #expect(commands.contains(.data(id: id.rawValue, bytes)))

        let success = codec.encodeStatus(id: id.rawValue, result: .success)
        let successPacket = try #require(VDAgentWireEncoder.fragments(for: success).first)
        await transport.enqueue(encodeMini(id: 109, body: successPacket))
        #expect(await events.next() == .completed(id: id))

        await manager.stop()
        await session.disconnect()
    }

    @Test func fileStatusAndCancelDuringSendingDataDoNotDuplicateWireOwner() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 32
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        var clipboardEvents = manager.events.makeAsyncIterator()
        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        await transport.enqueue(encodeMini(
            id: 109,
            body: try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        ))
        #expect(await clipboardEvents.next() == .ready)

        let bytes = Data(repeating: 0xa5, count: 3_000)
        let source = FileManager.default.temporaryDirectory.appending(
            path: "spice-swift-inflight-cancel-\(UUID().uuidString).bin"
        )
        try bytes.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        var events = manager.fileTransferEvents.makeAsyncIterator()
        let id = try await manager.sendFile(at: source, name: "fixture.bin")
        #expect(await events.next() == .queued(
            id: id,
            name: "fixture.bin",
            totalBytes: UInt64(bytes.count)
        ))
        #expect(await events.next() == .awaitingGuestApproval(id: id))

        let agentWritesBeforeData = await transport.agentWriteCount
        await transport.blockAgentWrites(afterWrittenCount: agentWritesBeforeData + 1)
        let codec = VDAgentFileTransferCodec()
        let dataOwner = Task {
            await manager.receiveFileTransferCommandForTesting(.status(
                VDAgentFileTransferStatus(
                    id: id.rawValue,
                    result: .canSendData,
                    detail: nil
                )
            ))
        }
        await transport.waitForBlockedAgentWriteCount(1)
        dataOwner.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(await manager.fileTransferSentByteCount(id) == 0)

        await manager.cancelFileTransfer(id)
        await manager.receiveFileTransferCommandForTesting(.status(
            VDAgentFileTransferStatus(
                id: id.rawValue,
                result: .cancelled,
                detail: nil
            )
        ))
        #expect(await transport.blockedAgentWriteCount == 1)
        #expect(await manager.fileTransferSentByteCount(id) == 0)
        await transport.releaseBlockedAgentWrites()
        await dataOwner.value

        #expect(await events.next() == .progress(
            id: id,
            sentBytes: UInt64(bytes.count),
            totalBytes: UInt64(bytes.count)
        ))
        #expect(await events.next() == .cancelled(id: id))
        let commands = try decodedAgentMessages(await transport.outbound).compactMap {
            try codec.decode($0)
        }
        #expect(commands.filter {
            guard case let .data(commandID, data) = $0 else { return false }
            return commandID == id.rawValue && data == bytes
        }.count == 1)
        #expect(commands.filter { $0 == .status(VDAgentFileTransferStatus(
            id: id.rawValue,
            result: .cancelled,
            detail: nil
        )) }.isEmpty)

        await manager.stop()
        await session.disconnect()
    }

    @Test func cancelAndApprovalDuringBlockedStartStillSendExactlyOneCancellation() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 32
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        var clipboardEvents = manager.events.makeAsyncIterator()
        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        await transport.enqueue(encodeMini(
            id: 109,
            body: try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        ))
        #expect(await clipboardEvents.next() == .ready)

        let source = FileManager.default.temporaryDirectory.appending(
            path: "spice-swift-start-cancel-\(UUID().uuidString).bin"
        )
        try Data([1, 2, 3]).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        await transport.blockAgentMessages(types: [
            VDAgentMessageType.fileTransferStart.rawValue,
        ])
        var events = manager.fileTransferEvents.makeAsyncIterator()
        let send = Task {
            try await manager.sendFile(at: source, name: "fixture.bin")
        }
        let queued = try #require(await events.next())
        let id: SpiceFileTransferID
        if case let .queued(queuedID, _, _) = queued {
            id = queuedID
        } else {
            Issue.record("expected queued file-transfer event")
            return
        }
        await transport.waitForBlockedAgentWriteCount(1)

        await manager.cancelFileTransfer(id)
        let codec = VDAgentFileTransferCodec()
        let canSend = codec.encodeStatus(id: id.rawValue, result: .canSendData)
        await transport.enqueue(encodeMini(
            id: 109,
            body: try #require(VDAgentWireEncoder.fragments(for: canSend).first)
        ))
        await transport.releaseBlockedAgentWrites()
        #expect(try await send.value == id)

        while true {
            let commands = try decodedAgentMessages(await transport.outbound).compactMap {
                try codec.decode($0)
            }
            if commands.contains(.status(VDAgentFileTransferStatus(
                id: id.rawValue,
                result: .cancelled,
                detail: nil
            ))) {
                #expect(commands.filter {
                    if case let .start(commandID, _) = $0 { return commandID == id.rawValue }
                    return false
                }.count == 1)
                #expect(commands.filter { $0 == .status(VDAgentFileTransferStatus(
                    id: id.rawValue,
                    result: .cancelled,
                    detail: nil
                )) }.count == 1)
                break
            }
            await Task.yield()
        }

        let cancelled = codec.encodeStatus(id: id.rawValue, result: .cancelled)
        await transport.enqueue(encodeMini(
            id: 109,
            body: try #require(VDAgentWireEncoder.fragments(for: cancelled).first)
        ))
        // No stale awaitingGuestApproval event may precede the terminal event.
        #expect(await events.next() == .cancelled(id: id))
        await manager.stop()
        await session.disconnect()
    }

    @Test func queuedFileCancellationSendsNoFilePayloadBeforeCapabilities() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        let source = FileManager.default.temporaryDirectory.appending(
            path: "spice-swift-cancel-\(UUID().uuidString).bin"
        )
        try Data([9]).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        var events = manager.fileTransferEvents.makeAsyncIterator()
        let id = try await manager.sendFile(at: source)
        #expect(await events.next() == .queued(
            id: id,
            name: source.lastPathComponent,
            totalBytes: 1
        ))
        await manager.cancelFileTransfer(id)
        #expect(await events.next() == .cancelled(id: id))

        let outbound = await transport.outbound
        let agentPackets = try outbound.compactMap { packet -> Data? in
            guard packet.count >= 6, try decodeMiniMessageID(packet) == 107 else {
                return nil
            }
            return try decodeMiniBody(packet)
        }
        var decoder = VDAgentStreamDecoder()
        let messages = try agentPackets.flatMap { try decoder.append(packet: $0) }
        #expect(!messages.contains(where: {
            $0.type == VDAgentMessageType.fileTransferStart.rawValue
                || $0.type == VDAgentMessageType.fileTransferData.rawValue
        }))

        await manager.stop()
        await session.disconnect()
    }

    @Test func truncatedSourceNotifiesGuestWithTransferError() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        var clipboardEvents = manager.events.makeAsyncIterator()
        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        await transport.enqueue(encodeMini(
            id: 109,
            body: try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        ))
        #expect(await clipboardEvents.next() == .ready)

        let source = FileManager.default.temporaryDirectory.appending(
            path: "spice-swift-truncate-\(UUID().uuidString).bin"
        )
        try Data([1, 2, 3, 4]).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        var events = manager.fileTransferEvents.makeAsyncIterator()
        let id = try await manager.sendFile(at: source)
        _ = await events.next()
        #expect(await events.next() == .awaitingGuestApproval(id: id))

        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: 0)
        try writer.close()
        let codec = VDAgentFileTransferCodec()
        let canSend = codec.encodeStatus(id: id.rawValue, result: .canSendData)
        await transport.enqueue(encodeMini(
            id: 109,
            body: try #require(VDAgentWireEncoder.fragments(for: canSend).first)
        ))
        let failure = try #require(await events.next())
        guard case let .failed(failedID, error) = failure else {
            Issue.record("expected local read failure")
            return
        }
        #expect(failedID == id)
        guard case .localReadFailed = error else {
            Issue.record("expected localReadFailed, got \(error)")
            return
        }

        let outbound = await transport.outbound
        let agentPackets = try outbound.compactMap { packet -> Data? in
            guard packet.count >= 6, try decodeMiniMessageID(packet) == 107 else {
                return nil
            }
            return try decodeMiniBody(packet)
        }
        var decoder = VDAgentStreamDecoder()
        let messages = try agentPackets.flatMap { try decoder.append(packet: $0) }
        let commands = try messages.compactMap { try codec.decode($0) }
        #expect(commands.contains(.status(VDAgentFileTransferStatus(
            id: id.rawValue,
            result: .error,
            detail: nil
        ))))

        await manager.stop()
        await session.disconnect()
    }

    @Test func cancellationWhileAttachingChannelsClosesEveryTransport() async throws {
        let mainTransport = FakeTransport(
            inbound: try makeServerTranscript().map(Result.success)
        )
        let displayTransport = FakeTransport(
            inbound: try makeLinkResponses().map(Result.success)
        )
        let blockedInputsTransport = BlockingTransport()
        let transports = TransportPool([
            mainTransport,
            displayTransport,
            blockedInputsTransport,
        ])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )

        let connectionTask = Task {
            try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        await blockedInputsTransport.waitUntilFirstWrite()
        #expect(await blockedInputsTransport.outboundCount == 1)
        connectionTask.cancel()

        do {
            _ = try await connectionTask.value
            Issue.record("cancelled connection unexpectedly succeeded")
        } catch let error as SpiceError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
        #expect(await mainTransport.isClosed)
        #expect(await displayTransport.isClosed)
        #expect(await blockedInputsTransport.isClosed)
    }

    @Test func preparedMigrationAtomicallyAdoptsTargetAfterEnd() async throws {
        let inputChannel = [SpiceChannelID(type: 3, id: 0)]
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: inputChannel
        ))
        let sourceInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let targetMouseMode = SpiceMsgMainMouseMode(supportedModes: 7, currentMode: 1)
        let target = StreamingSessionTransport(
            initial: try makeLinkResponses() + [encodeMini(targetMouseMode)]
        )
        let targetInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, sourceInputs, target, targetInputs])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()
        try await session.send(.keyDown(scanCode: 0x1e))
        await sourceInputs.waitForOutboundCount(3)
        let sourceInputCount = await sourceInputs.outbound.count
        await source.enqueue(encodeMini(id: 101, body: migrationDestinationBody(
            host: "target.example"
        )))

        let offer = try #require(preparingOffer(await events.next()))
        #expect(offer.destination.host == "target.example")
        #expect(offer.mode == .semiSeamless)
        #expect(await events.next() == .migration(.ready(offer, seamless: false)))
        await source.waitForOutboundCount(5)
        #expect(try decodeMiniMessageID((await source.outbound).last ?? Data()) == 102)
        #expect(await source.isConnected)
        #expect(await target.isConnected)

        await source.enqueue(encodeMini(id: 112, body: Data()))
        #expect(await events.next() == .migration(.committing(offer)))

        var sawCompletion = false
        var sawTargetMouseMode = false
        for _ in 0 ..< 2 {
            switch await events.next() {
            case let .migration(.completed(completedOffer)):
                #expect(completedOffer == offer)
                sawCompletion = true
            case .mouseMode(supported: 7, current: 1):
                sawTargetMouseMode = true
            default:
                Issue.record("unexpected post-adoption event")
            }
        }
        #expect(sawCompletion)
        #expect(sawTargetMouseMode)
        await target.waitForOutboundCount(4)
        #expect(try decodeMiniMessageID((await target.outbound).last ?? Data()) == 109)
        #expect(!(await source.isConnected))
        #expect(await target.isConnected)
        #expect(!(await sourceInputs.isConnected))
        #expect(await targetInputs.isConnected)
        let targetInputLink = try decodeLinkRequest(
            try #require((await targetInputs.outbound).first)
        )
        #expect(targetInputLink.connectionID == 77)
        let targetInputCount = await targetInputs.outbound.count
        try await session.send(.keyDown(scanCode: 0x30))
        await targetInputs.waitForOutboundCount(targetInputCount + 1)
        #expect(await sourceInputs.outbound.count == sourceInputCount)
        #expect(await targetInputs.outbound.count == targetInputCount + 1)
        await session.disconnect()
        #expect(!(await target.isConnected))
        #expect(!(await targetInputs.isConnected))
    }

    @Test func nonSeamlessEndGateRejectsConcurrentSourceAgentWrites() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let target = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, target])
        let endGate = MigrationEndGate()
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationTargetEndHook: {
                await endGate.intercept()
            }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()
        await source.enqueue(encodeMini(id: 101, body: migrationDestinationBody(
            host: "target.example"
        )))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: false)))

        await source.enqueue(encodeMini(id: 112, body: Data()))
        #expect(await events.next() == .migration(.committing(offer)))
        await endGate.waitUntilBlocked()
        let sourceAgentWrites = await source.agentWriteCount
        await #expect(throws: SpiceError.agentMigrationRebind(partial: false)) {
            try await session.sendAgentMessage(SpiceAgentMessage(
                protocolID: 1,
                type: VDAgentMessageType.clipboardRelease.rawValue,
                opaque: 0,
                data: Data()
            ))
        }
        #expect(await source.agentWriteCount == sourceAgentWrites)
        #expect(await target.agentWriteCount == 0)

        await endGate.release()
        #expect(await events.next() == .migration(.completed(offer)))
        await session.disconnect()
    }

    @Test func supersededNonSeamlessCommitFailsClosedBeforeTargetEnd() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let firstTarget = StreamingSessionTransport(initial: try makeLinkResponses())
        let secondTarget = BlockingTransport()
        let transports = TransportPool([source, firstTarget, secondTarget])
        let endGate = MigrationEndGate()
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationTargetEndHook: { await endGate.intercept() }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()

        await source.enqueue(encodeMini(
            id: 101,
            body: migrationDestinationBody(host: "first.example")
        ))
        let first = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(first, seamless: false)))
        let firstTargetOutboundBaseline = (await firstTarget.outbound).count
        await source.enqueue(encodeMini(id: 112, body: Data()))
        #expect(await events.next() == .migration(.committing(first)))
        await endGate.waitUntilBlocked()

        await source.enqueue(encodeMini(
            id: 101,
            body: migrationDestinationBody(host: "second.example")
        ))
        #expect(await events.next() == .migration(.cancelled(first)))
        _ = try #require(preparingOffer(await events.next()))
        await secondTarget.waitUntilFirstWrite()
        await endGate.release()

        guard case .failed = await events.next() else {
            Issue.record("superseded gated commit must fail the whole session closed")
            return
        }
        #expect((await firstTarget.outbound).count == firstTargetOutboundBaseline)
        #expect(await source.waitUntilDisconnected())
        #expect(await firstTarget.waitUntilDisconnected())
        await secondTarget.waitUntilClosed()
        #expect(await secondTarget.isClosed)
    }

    @Test func supersededSwitchFailsClosedBeforePublishingOldTarget() async throws {
        let inputChannels = [SpiceChannelID(type: 3, id: 0)]
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: inputChannels
        ))
        let sourceInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let firstTarget = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: inputChannels
        ))
        let firstTargetInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let secondTarget = BlockingTransport()
        let transports = TransportPool([
            source,
            sourceInputs,
            firstTarget,
            firstTargetInputs,
            secondTarget,
        ])
        let activationGate = MigrationInputActivationGate()
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationReplacementHook: { phase, key in
                await activationGate.intercept(phase: phase, key: key)
            }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let sourceSender = try await session.makeInputSender()
        var events = session.events.makeAsyncIterator()

        await source.enqueue(encodeMini(
            id: 111,
            body: migrationDestinationBody(host: "first.example")
        ))
        guard case let .migration(.switching(first)) = await events.next() else {
            Issue.record("expected first switch offer")
            return
        }
        await activationGate.waitUntilBlocked()

        await source.enqueue(encodeMini(
            id: 111,
            body: migrationDestinationBody(host: "second.example")
        ))
        #expect(await events.next() == .migration(.cancelled(first)))
        guard case .migration(.switching) = await events.next() else {
            Issue.record("expected replacement switch offer")
            return
        }
        await secondTarget.waitUntilFirstWrite()
        await activationGate.release()

        guard case .failed = await events.next() else {
            Issue.record("superseded gated switch must fail the whole session closed")
            return
        }
        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await sourceSender.send(.keyDown(scanCode: 0x1e))
        }
        #expect(await source.waitUntilDisconnected())
        #expect(await sourceInputs.waitUntilDisconnected())
        #expect(await firstTarget.waitUntilDisconnected())
        #expect(await firstTargetInputs.waitUntilDisconnected())
        await secondTarget.waitUntilClosed()
        #expect(await secondTarget.isClosed)
    }

    @Test func nonSeamlessApplyFailureFailsClosedWithoutSourceRestart() async throws {
        let inputChannel = [SpiceChannelID(type: 3, id: 0)]
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: inputChannel
        ))
        let sourceInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let target = StreamingSessionTransport(initial: try makeLinkResponses())
        let targetInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, sourceInputs, target, targetInputs])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationReplacementHook: { phase, key in
                if case .applying = phase, key.type == 3 {
                    throw ChannelError.protocolViolation("fixture nonseamless apply failure")
                }
            }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let sourceSender = try await session.makeInputSender()
        var events = session.events.makeAsyncIterator()
        await source.enqueue(encodeMini(id: 101, body: migrationDestinationBody(
            host: "target.example"
        )))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: false)))

        await source.enqueue(encodeMini(id: 112, body: Data()))
        #expect(await events.next() == .migration(.committing(offer)))
        let failure = await events.next()
        guard case let .failed(error) = failure else {
            Issue.record("expected full-session failure, got \(String(describing: failure))")
            return
        }
        #expect(error.description.contains("fixture nonseamless apply failure"))
        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await sourceSender.send(.keyDown(scanCode: 0x1e))
        }
        #expect(await source.waitUntilDisconnected())
        #expect(await sourceInputs.waitUntilDisconnected())
        #expect(await target.waitUntilDisconnected())
        #expect(await targetInputs.waitUntilDisconnected())
    }

    @Test func committedTargetImmediateFailureFailsClosedWithoutSourceRollback() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        // prepareMigrationConnection consumes only the link handshake.  The
        // queued MainInit is invalid for the rebound, already-bootstrapped
        // source Main actor and fails target supervision immediately after the
        // atomic admission commit.
        let target = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let transports = TransportPool([source, target])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()
        await source.enqueue(encodeMini(id: 101, body: migrationDestinationBody(
            host: "target.example"
        )))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: false)))

        await source.enqueue(encodeMini(id: 112, body: Data()))
        #expect(await events.next() == .migration(.committing(offer)))
        let firstTerminal = await events.next()
        switch firstTerminal {
        case let .migration(.completed(completedOffer)):
            #expect(completedOffer == offer)
            guard case .failed = await events.next() else {
                Issue.record("committed target failure must close the session")
                return
            }
        case .failed:
            break
        default:
            Issue.record("unexpected target failure event: \(String(describing: firstTerminal))")
            return
        }
        #expect(await source.waitUntilDisconnected())
        #expect(await target.waitUntilDisconnected())
    }

    @Test func midInventoryMigrationFailureRollsBackAndRestartsSourceSupervision() async throws {
        let sourceChannels = [
            SpiceChannelID(type: 2, id: 0),
            SpiceChannelID(type: 3, id: 0),
        ]
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: sourceChannels,
            agentConnected: 1,
            agentTokens: 8
        ))
        let sourceDisplay = StreamingSessionTransport(initial: try makeLinkResponses())
        let sourceInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let target = StreamingSessionTransport(
            initial: try makeLinkResponses(mainCapabilities: [0x8])
                + [encodeMini(id: 117, body: Data())]
        )
        let targetDisplay = StreamingSessionTransport(initial: try makeLinkResponses())
        let targetInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([
            source,
            sourceDisplay,
            sourceInputs,
            target,
            targetDisplay,
            targetInputs,
        ])
        let failingKey = ChannelKey(type: 3, id: 0)
        let replacementGate = MigrationReplacementGate(failingKey: failingKey)
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationReplacementHook: { phase, key in
                try await replacementGate.intercept(phase: phase, key: key)
            }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()

        await source.enqueue(encodeMini(
            id: 116,
            body: migrationDestinationBody(host: "target.example") + uint32(9)
        ))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: true)))

        await source.enqueue(encodeMini(id: 1, body: uint32(1)))
        await sourceDisplay.enqueue(encodeMini(id: 1, body: uint32(1)))
        await sourceInputs.enqueue(encodeMini(id: 1, body: uint32(1)))
        #expect(await events.next() == .migration(.committing(offer)))
        await replacementGate.waitUntilBlocked()
        await #expect(throws: SpiceError.agentMigrationRebind(partial: false)) {
            try await session.sendAgentMessage(SpiceAgentMessage(
                protocolID: 1,
                type: VDAgentMessageType.clipboardRelease.rawValue,
                opaque: 0,
                data: Data()
            ))
        }
        #expect(await target.agentWriteCount == 0)
        await replacementGate.releaseWithFailure()

        let failure = await events.next()
        if case let .migration(.failed(failedOffer, reason)) = failure {
            #expect(failedOffer == offer)
            #expect(!reason.isEmpty)
        } else {
            Issue.record("expected migration failure after rollback, got \(String(describing: failure))")
        }
        while true {
            let targetMainConnected = await target.isConnected
            let targetDisplayConnected = await targetDisplay.isConnected
            let targetInputsConnected = await targetInputs.isConnected
            guard targetMainConnected || targetDisplayConnected || targetInputsConnected else {
                break
            }
            await Task.yield()
        }
        #expect(await source.isConnected)
        #expect(await sourceDisplay.isConnected)
        #expect(await sourceInputs.isConnected)

        await source.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 7, currentMode: 2)
        ))
        #expect(await events.next() == .mouseMode(supported: 7, current: 2))
        let sourceInputCount = await sourceInputs.outbound.count
        try await session.send(.keyDown(scanCode: 0x1e))
        await sourceInputs.waitForOutboundCount(sourceInputCount + 1)
        #expect(await sourceInputs.outbound.count == sourceInputCount + 1)

        await session.disconnect()
    }

    @Test func seamlessRollbackExpiresQueuedInputBeforeItCanReachFreshGeneration() async throws {
        let sourceChannels = [
            SpiceChannelID(type: 2, id: 0),
            SpiceChannelID(type: 3, id: 0),
        ]
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: sourceChannels
        ))
        let sourceDisplay = StreamingSessionTransport(initial: try makeLinkResponses())
        let sourceInputs = BlockingEventSessionTransport(initial: try makeLinkResponses())
        let target = StreamingSessionTransport(
            initial: try makeLinkResponses(mainCapabilities: [0x8])
                + [encodeMini(id: 117, body: Data())]
        )
        let targetDisplay = StreamingSessionTransport(initial: try makeLinkResponses())
        let targetInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([
            source,
            sourceDisplay,
            sourceInputs,
            target,
            targetDisplay,
            targetInputs,
        ])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationReplacementHook: { phase, key in
                if case .applying = phase, key == ChannelKey(type: 2, id: 0) {
                    throw ChannelError.protocolViolation("fixture early Display apply failure")
                }
            }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let sourceSender = try await session.makeInputSender()
        let active = Task { try await sourceSender.send(.mousePress(.left)) }
        await sourceInputs.waitUntilEventWriteStarts()
        let queued = Task { try await sourceSender.send(.mousePress(.right)) }
        await session.waitUntilInputSendIsQueuedForTesting()
        let sourceInputBaseline = (await sourceInputs.outbound).count
        var events = session.events.makeAsyncIterator()

        await source.enqueue(encodeMini(
            id: 116,
            body: migrationDestinationBody(host: "target.example") + uint32(9)
        ))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: true)))
        await source.enqueue(encodeMini(id: 1, body: uint32(1)))
        await sourceDisplay.enqueue(encodeMini(id: 1, body: uint32(1)))
        await sourceInputs.enqueue(encodeMini(id: 1, body: uint32(1)))
        #expect(await events.next() == .migration(.committing(offer)))

        guard case let .migration(.failed(failedOffer, reason)) = await events.next() else {
            Issue.record("expected a rollback-complete migration failure")
            return
        }
        #expect(failedOffer == offer)
        #expect(reason.contains("fixture early Display apply failure"))
        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await queued.value
        }
        #expect((await sourceInputs.outbound).count == sourceInputBaseline + 1)

        await sourceInputs.completeEventWrite()
        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await active.value
        }
        let freshSender = try await session.makeInputSender()
        try await freshSender.send(.mouseMotion(dx: 4, dy: 5))

        let outbound = await sourceInputs.outbound
        #expect(outbound.count == sourceInputBaseline + 3)
        #expect(try decodeMiniMessageID(outbound[sourceInputBaseline + 1]) == 113)
        #expect(try decodeMiniMessageID(outbound[sourceInputBaseline + 2]) == 111)
        #expect(try inputButtonsState(outbound[sourceInputBaseline + 2], offset: 8) == 0)
        await session.disconnect()
    }

    @Test func seamlessTargetRebindsInputGenerationAfterNegotiation() async throws {
        let inputChannel = [SpiceChannelID(type: 3, id: 0)]
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: inputChannel
        ))
        let sourceInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let target = StreamingSessionTransport(
            initial: try makeLinkResponses(mainCapabilities: [0x8])
                + [encodeMini(id: 117, body: Data())]
        )
        let targetInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, sourceInputs, target, targetInputs])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let sourceInputSender = try await session.makeInputSender()
        var events = session.events.makeAsyncIterator()
        await source.enqueue(encodeMini(
            id: 116,
            body: migrationDestinationBody(host: "target.example") + uint32(9)
        ))

        let offer = try #require(preparingOffer(await events.next()))
        #expect(offer.mode == .seamless(sourceVersion: 9))
        #expect(await events.next() == .migration(.ready(offer, seamless: true)))

        try await sourceInputSender.send(.mousePress(.left))
        await sourceInputs.waitForOutboundCount(3)

        await target.waitForOutboundCount(4)
        let targetOutbound = await target.outbound
        #expect(try decodeMiniMessageID(targetOutbound.last ?? Data()) == 110)
        #expect(try decodeMiniBody(targetOutbound.last ?? Data()) == uint32(9))
        await source.waitForOutboundCount(5)
        #expect(try decodeMiniMessageID((await source.outbound).last ?? Data()) == 111)

        let mainState = Data("main-state".utf8)
        let inputsState = Data("inputs-state".utf8)
        await source.enqueue(encodeMini(id: 1, body: uint32(3)))
        await source.enqueue(encodeMini(id: 2, body: mainState))
        await source.waitForOutboundCount(6)
        #expect(try decodeMiniMessageID((await source.outbound).last ?? Data()) == 4)
        while !(await session.isChannelMigrationFlushing()) { await Task.yield() }
        await #expect(throws: SpiceError.protocolError(
            "channel migration is flushing client messages"
        )) {
            try await session.send(.keyDown(scanCode: 0x1e))
        }

        await sourceInputs.enqueue(encodeMini(id: 1, body: uint32(3)))
        await sourceInputs.enqueue(encodeMini(id: 2, body: inputsState))
        #expect(await events.next() == .migration(.committing(offer)))
        #expect(await events.next() == .migration(.completed(offer)))

        await target.waitForOutboundCount(5)
        #expect(try decodeMiniMessageID((await target.outbound).last ?? Data()) == 5)
        #expect(try decodeMiniBody((await target.outbound).last ?? Data()) == mainState)
        await targetInputs.waitForOutboundCount(4)
        #expect(try decodeMiniMessageID((await targetInputs.outbound).last ?? Data()) == 5)
        #expect(try decodeMiniBody((await targetInputs.outbound).last ?? Data()) == inputsState)
        #expect(await source.waitUntilDisconnected())
        #expect(await sourceInputs.waitUntilDisconnected())
        #expect(!(await source.isConnected))
        #expect(!(await sourceInputs.isConnected))
        #expect(await target.isConnected)
        #expect(await targetInputs.isConnected)

        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await sourceInputSender.send(.mousePosition(x: 1, y: 2, displayID: 0))
        }
        let targetInputSender = try await session.makeInputSender()
        #expect(targetInputSender.generation != sourceInputSender.generation)

        let targetInputCount = await targetInputs.outbound.count
        try await targetInputSender.send(.mousePosition(x: 40, y: 50, displayID: 0))
        await targetInputs.waitForOutboundCount(targetInputCount + 1)
        let reboundInput = try #require((await targetInputs.outbound).last)
        #expect(try decodeMiniMessageID(reboundInput) == 112)
        var reboundBody = try ByteReader(try decodeMiniBody(reboundInput), offset: 8)
        #expect(try reboundBody.readUInt16LE() == 1)
        await session.disconnect()
    }

    @Test func migrationEndpointPolicyPreservesTLSAndRejectsUnsafeTargets() throws {
        #expect(try SpiceSession.selectMigrationEndpoint(
            destination: .init(
                host: "target.example",
                port: 5_900,
                securePort: 5_901,
                certificateSubject: nil
            ),
            current: SpiceEndpoint(host: "source", port: 5_900)
        ) == SpiceEndpoint(host: "target.example", port: 5_900))
        #expect(try SpiceSession.selectMigrationEndpoint(
            destination: .init(
                host: "target.example",
                port: 5_900,
                securePort: 5_901,
                certificateSubject: nil
            ),
            current: SpiceEndpoint(
                host: "source",
                port: 5_901,
                tlsPolicy: .insecureForTestingOnly,
                videoCodecPolicy: .h264AndMJPEG
            )
        ) == SpiceEndpoint(
            host: "target.example",
            port: 5_901,
            tlsPolicy: .insecureForTestingOnly,
            videoCodecPolicy: .h264AndMJPEG
        ))

        let virtViewerPolicy = TLSTrustPolicy.virtViewerCertificateAuthority(
            certificates: [Data([1, 2, 3])],
            expectedSubject: "C=SG,O=SwiftSpice,CN=target.example"
        )
        #expect(try SpiceSession.selectMigrationEndpoint(
            destination: .init(
                host: "target.example",
                port: 5_900,
                securePort: 5_901,
                certificateSubject: nil
            ),
            current: SpiceEndpoint(
                host: "source",
                port: 5_901,
                tlsPolicy: virtViewerPolicy
            )
        ) == SpiceEndpoint(
            host: "target.example",
            port: 5_901,
            tlsPolicy: virtViewerPolicy
        ))

        #expect(try SpiceSession.selectMigrationEndpoint(
            destination: .init(
                host: "secure.example",
                port: nil,
                securePort: 6_001,
                certificateSubject: nil
            ),
            current: SpiceEndpoint(host: "source", port: 5_900)
        ) == SpiceEndpoint(host: "secure.example", port: 6_001, tlsPolicy: .system))

        #expect(throws: SpiceError.protocolError(
            "refusing to downgrade a TLS migration target"
        )) {
            try SpiceSession.selectMigrationEndpoint(
                destination: .init(
                    host: "plain.example",
                    port: 6_000,
                    securePort: nil,
                    certificateSubject: nil
                ),
                current: SpiceEndpoint(host: "source", port: 5_901, tlsPolicy: .system)
            )
        }

        #expect(throws: SpiceError.protocolError(
            "migration certificate-subject verification is not implemented"
        )) {
            try SpiceSession.selectMigrationEndpoint(
                destination: .init(
                    host: "secure.example",
                    port: nil,
                    securePort: 6_001,
                    certificateSubject: "CN=secure.example"
                ),
                current: SpiceEndpoint(host: "source", port: 5_900)
            )
        }
    }

    @Test func cancelAfterPartialChannelFlushResumesSourceChannel() async throws {
        let inputChannel = [SpiceChannelID(type: 3, id: 0)]
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: inputChannel
        ))
        let sourceInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let target = StreamingSessionTransport(
            initial: try makeLinkResponses(mainCapabilities: [0x8])
                + [encodeMini(id: 117, body: Data())]
        )
        let targetInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([source, sourceInputs, target, targetInputs])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()
        await source.enqueue(encodeMini(
            id: 116,
            body: migrationDestinationBody(host: "target.example") + uint32(9)
        ))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: true)))

        await sourceInputs.enqueue(encodeMini(id: 1, body: uint32(1)))
        await sourceInputs.waitForOutboundCount(4)
        while !(await session.isChannelMigrationFlushing()) { await Task.yield() }

        await source.enqueue(encodeMini(id: 102, body: Data()))
        #expect(await events.next() == .migration(.cancelled(offer)))
        while await session.isChannelMigrationFlushing() { await Task.yield() }
        while await target.isConnected { await Task.yield() }
        while await targetInputs.isConnected { await Task.yield() }

        let sourceInputCount = await sourceInputs.outbound.count
        try await session.send(.keyDown(scanCode: 0x1e))
        await sourceInputs.waitForOutboundCount(sourceInputCount + 1)
        #expect(await sourceInputs.isConnected)
        await session.disconnect()
    }

    @Test func failedMigrationPreparationClosesTargetAndKeepsSourceSupervised() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let target = FakeTransport(inbound: [
            .failure(.connectionFailed("target fixture rejected handshake")),
        ])
        let transports = TransportPool([source, target])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()
        await source.enqueue(encodeMini(id: 101, body: migrationDestinationBody(
            host: "broken-target.example"
        )))

        let offer = try #require(preparingOffer(await events.next()))
        let failedEvent = await events.next()
        if case let .migration(.failed(failedOffer, reason)) = failedEvent {
            #expect(failedOffer == offer)
            #expect(reason.contains("target fixture rejected handshake"))
        } else {
            Issue.record("expected migration failure event, got \(String(describing: failedEvent))")
        }

        await source.waitForOutboundCount(5)
        let outbound = await source.outbound
        #expect(try decodeMiniMessageID(outbound.last ?? Data()) == 103)
        #expect(await target.isClosed)
        #expect(await source.isConnected)

        await source.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 2)
        ))
        #expect(await events.next() == .mouseMode(supported: 3, current: 2))
        #expect(await session.currentAgentConnectionState() == false)
        await session.disconnect()
    }

    @Test func cancellingMigrationPreparationClosesOnlyTargetTransport() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let target = BlockingTransport()
        let transports = TransportPool([source, target])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()
        await source.enqueue(encodeMini(id: 101, body: migrationDestinationBody(
            host: "slow-target.example"
        )))
        let offer = try #require(preparingOffer(await events.next()))
        await target.waitUntilFirstWrite()

        await source.enqueue(encodeMini(id: 102, body: Data()))
        #expect(await events.next() == .migration(.cancelled(offer)))
        await target.waitUntilClosed()
        #expect(await target.isClosed)
        #expect(await source.isConnected)

        await source.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 1, currentMode: 1)
        ))
        #expect(await events.next() == .mouseMode(supported: 1, current: 1))
        await session.disconnect()
    }

    @Test func newerMigrationCancelsInFlightPreparationAndCommitsOnlyAfterEnd() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let executor = ControlledMigrationExecutor()
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationExecutor: executor
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()

        await transport.enqueue(encodeMini(id: 101, body: migrationDestinationBody(host: "first")))
        let first = try #require(preparingOffer(await events.next()))
        await executor.waitUntilPreparing(first.id)

        await transport.enqueue(encodeMini(id: 101, body: migrationDestinationBody(host: "second")))
        #expect(await events.next() == .migration(.cancelled(first)))
        let second = try #require(preparingOffer(await events.next()))
        await executor.waitUntilCancelled(first.id)
        await executor.waitUntilPreparing(second.id)

        await executor.completePreparation(second.id, seamless: false)
        #expect(await events.next() == .migration(.ready(second, seamless: false)))
        await transport.waitForOutboundCount(5)
        #expect(try decodeMiniMessageID((await transport.outbound).last ?? Data()) == 102)

        await transport.enqueue(encodeMini(id: 112, body: Data()))
        #expect(await events.next() == .migration(.committing(second)))
        #expect(await events.next() == .migration(.completed(second)))
        #expect(await executor.committedOffers == [second])
        await session.disconnect()
    }

    @Test func stalePreparationCallbackCannotClearNewerMigrationOwner() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let executor = NonCooperativeMigrationExecutor()
        let preparationGate = MigrationCompletionGate()
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationExecutor: executor,
            migrationPreparationCompletionHook: { offerID, operationID in
                await preparationGate.intercept(
                    offerID: offerID,
                    operationID: operationID
                )
            }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()

        await transport.enqueue(encodeMini(
            id: 101,
            body: migrationDestinationBody(host: "first.example")
        ))
        let first = try #require(preparingOffer(await events.next()))
        await executor.waitUntilPreparing(first.id)
        await executor.completePreparation(first.id, seamless: false)
        await preparationGate.waitUntilBlocked()

        await transport.enqueue(encodeMini(
            id: 101,
            body: migrationDestinationBody(host: "second.example")
        ))
        #expect(await events.next() == .migration(.cancelled(first)))
        let second = try #require(preparingOffer(await events.next()))
        await executor.waitUntilPreparing(second.id)

        let callbackBaseline = await session.migrationCallbackAttemptSequenceForTesting()
        await preparationGate.release()
        await session.waitUntilMigrationCallbackAttemptsForTesting(after: callbackBaseline)

        await transport.enqueue(encodeMini(
            id: 101,
            body: migrationDestinationBody(host: "third.example")
        ))
        #expect(await events.next() == .migration(.cancelled(second)))
        let third = try #require(preparingOffer(await events.next()))
        await executor.waitUntilPreparing(third.id)
        await executor.waitUntilTaskCancelled(second.id)

        await session.disconnect()
        await executor.waitUntilTaskCancelled(third.id)
        await executor.finishAllPreparations()
    }

    @Test func staleSeamlessCompletionCannotClearNewerMigrationOwner() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let firstTarget = StreamingSessionTransport(
            initial: try makeLinkResponses(mainCapabilities: [0x8])
                + [encodeMini(id: 117, body: Data())]
        )
        let secondTarget = BlockingTransport()
        let thirdTarget = BlockingTransport()
        let transports = TransportPool([
            source,
            firstTarget,
            secondTarget,
            thirdTarget,
        ])
        let completionGate = MigrationCompletionGate()
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            migrationCompletionHook: { offerID, operationID in
                await completionGate.intercept(
                    offerID: offerID,
                    operationID: operationID
                )
            }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()

        await source.enqueue(encodeMini(
            id: 116,
            body: migrationDestinationBody(host: "first.example") + uint32(9)
        ))
        let first = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(first, seamless: true)))
        await source.enqueue(encodeMini(id: 1, body: uint32(1)))
        #expect(await events.next() == .migration(.committing(first)))
        await completionGate.waitUntilBlocked()

        await firstTarget.enqueue(encodeMini(
            id: 101,
            body: migrationDestinationBody(host: "second.example")
        ))
        #expect(await events.next() == .migration(.cancelled(first)))
        let second = try #require(preparingOffer(await events.next()))
        await secondTarget.waitUntilFirstWrite()

        let completionAttemptBaseline =
            await session.migrationCallbackAttemptSequenceForTesting()
        await completionGate.release()
        await session.waitUntilMigrationCallbackAttemptsForTesting(
            after: completionAttemptBaseline
        )
        await firstTarget.enqueue(encodeMini(
            id: 101,
            body: migrationDestinationBody(host: "third.example")
        ))
        #expect(await events.next() == .migration(.cancelled(second)))
        _ = try #require(preparingOffer(await events.next()))
        await secondTarget.waitUntilClosed()
        await thirdTarget.waitUntilFirstWrite()

        await session.disconnect()
        await thirdTarget.waitUntilClosed()
        #expect(await secondTarget.isClosed)
        #expect(await thirdTarget.isClosed)
    }

    @Test func inputGenerationsAreScopedToTheirOwningSession() async throws {
        let channels = [SpiceChannelID(type: 3, id: 0)]
        let firstMain = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let firstInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let secondMain = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let secondInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let firstPool = TransportPool([firstMain, firstInputs])
        let secondPool = TransportPool([secondMain, secondInputs])
        let firstSession = SpiceSession(
            transportFactory: { _ in firstPool.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        let secondSession = SpiceSession(
            transportFactory: { _ in secondPool.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )

        _ = try await firstSession.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        _ = try await secondSession.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let firstSender = try await firstSession.makeInputSender()
        let secondSender = try await secondSession.makeInputSender()

        #expect(firstSender.generation != secondSender.generation)
        await firstSession.disconnect()
        await secondSession.disconnect()
    }

    @Test func fullSessionInputRecoveryRetainsFenceAcrossReplacementFailure() async throws {
        let channels = [SpiceChannelID(type: 3, id: 0)]
        let sourceMain = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let sourceInputs = FailingStreamingSessionTransport(
            initial: try makeLinkResponses(),
            failingWrites: [6]
        )
        let failedReplacementMain = StreamingSessionTransport(
            initial: try makeServerTranscript(channels: channels)
        )
        let failedReplacementInputs = FailingStreamingSessionTransport(
            initial: try makeLinkResponses(),
            failingWrites: [4]
        )
        let finalMain = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let finalInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([
            sourceMain,
            sourceInputs,
            failedReplacementMain,
            failedReplacementInputs,
            finalMain,
            finalInputs,
        ])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        let endpoint = SpiceEndpoint(host: "fixture.invalid", port: 5_900)

        _ = try await session.connect(
            endpoint: endpoint,
            credentials: SpiceCredentials(password: "secret")
        )
        let sourceSender = try await session.makeInputSender()
        try await sourceSender.send(.keyDown(scanCode: 0x1d))
        try await sourceSender.send(.mousePress(.left))
        await #expect(throws: SpiceError.self) {
            try await sourceSender.send(.mouseMotion(dx: 8, dy: -3))
        }
        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await sourceSender.send(.keyUp(scanCode: 0x1d))
        }

        let snapshot = SpiceInputRecoverySnapshot(
            possiblyPressedScanCodes: [0x1d],
            possiblyPressedButtons: [.left]
        )
        _ = try await session.connect(
            endpoint: endpoint,
            credentials: SpiceCredentials(password: "secret")
        )
        let failedReplacementSender = try await session.makeInputSender()
        #expect(failedReplacementSender.generation != sourceSender.generation)
        await #expect(throws: SpiceError.self) {
            try await failedReplacementSender.sendRecoveryFence(snapshot)
        }
        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await failedReplacementSender.send(.keyUp(scanCode: 0x1d))
        }

        _ = try await session.connect(
            endpoint: endpoint,
            credentials: SpiceCredentials(password: "secret")
        )
        let finalSender = try await session.makeInputSender()
        #expect(finalSender.generation != failedReplacementSender.generation)
        try await finalSender.sendRecoveryFence(snapshot)
        try await finalSender.send(.keyDown(scanCode: 0x1d))

        let recoveryMessages = Array((await finalInputs.outbound).dropFirst(3))
        #expect(try recoveryMessages.map(decodeMiniMessageID) == [114, 102, 101])
        await session.disconnect()
    }

    @Test func cancellationAfterInputWriteStartsInvalidatesItsGeneration() async throws {
        let channels = [SpiceChannelID(type: 3, id: 0)]
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let inputs = BlockingEventSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([main, inputs])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let sender = try await session.makeInputSender()

        let sendTask = Task {
            try await sender.send(.keyDown(scanCode: 0x1d))
        }
        await inputs.waitUntilEventWriteStarts()
        sendTask.cancel()
        await inputs.completeEventWrite()

        await #expect(throws: SpiceError.cancelled) {
            try await sendTask.value
        }
        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await sender.send(.keyUp(scanCode: 0x1d))
        }
        #expect(await inputs.isClosed)
    }

    @Test func cancellationBeforeQueuedInputWriteKeepsGenerationUsable() async throws {
        let channels = [SpiceChannelID(type: 3, id: 0)]
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let inputs = BlockingEventSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([main, inputs])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let sender = try await session.makeInputSender()

        let active = Task { try await sender.send(.keyDown(scanCode: 0x1d)) }
        await inputs.waitUntilEventWriteStarts()
        let queued = Task { try await sender.send(.keyDown(scanCode: 0x2a)) }
        await Task.yield()
        queued.cancel()

        await #expect(throws: SpiceError.cancelled) {
            try await queued.value
        }
        #expect(!(await inputs.isClosed))
        await inputs.completeEventWrite()
        try await active.value

        try await sender.send(.keyUp(scanCode: 0x1d))
        #expect(!(await inputs.isClosed))
        await session.disconnect()
    }

    @Test func disconnectExpiresActiveAndQueuedInputSends() async throws {
        let channels = [SpiceChannelID(type: 3, id: 0)]
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let inputs = BlockingEventSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([main, inputs])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let sender = try await session.makeInputSender()

        let active = Task { try await sender.send(.mousePress(.left)) }
        await inputs.waitUntilEventWriteStarts()
        let queued = Task { try await sender.send(.mousePress(.right)) }
        await Task.yield()
        let disconnect = Task { await session.disconnect() }

        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await queued.value
        }
        await #expect(throws: SpiceError.inputGenerationExpired) {
            try await active.value
        }
        await disconnect.value
        #expect(await inputs.isClosed)
    }

    @Test func connectCannotAdoptWhilePreviousChannelsAreClosing() async throws {
        let channels = [SpiceChannelID(type: 3, id: 0)]
        let oldMain = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let oldInputs = BlockingCloseSessionTransport(initial: try makeLinkResponses())
        let replacementMain = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: channels
        ))
        let replacementInputs = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([
            oldMain,
            oldInputs,
            replacementMain,
            replacementInputs,
        ])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        let endpoint = SpiceEndpoint(host: "fixture.invalid", port: 5_900)
        _ = try await session.connect(
            endpoint: endpoint,
            credentials: SpiceCredentials(password: "secret")
        )

        let disconnect = Task { await session.disconnect() }
        await oldInputs.waitUntilCloseStarts()
        await #expect(throws: SpiceError.cancelled) {
            _ = try await session.connect(
                endpoint: endpoint,
                credentials: SpiceCredentials(password: "secret")
            )
        }
        #expect(!(await replacementMain.isConnected))
        #expect(!(await replacementInputs.isConnected))

        await oldInputs.completeClose()
        await disconnect.value
        _ = try await session.connect(
            endpoint: endpoint,
            credentials: SpiceCredentials(password: "secret")
        )
        _ = try await session.makeInputSender()
        await session.disconnect()
        #expect(!(await replacementMain.isConnected))
        #expect(!(await replacementInputs.isConnected))
    }

    private func waitForOwnedAgentSendCount(
        _ count: Int,
        manager: SpiceAgentManager,
        maximumYields: Int = 10_000
    ) async {
        for _ in 0..<maximumYields {
            if await manager.ownedAgentSendCountForTesting() == count {
                return
            }
            await Task.yield()
        }
        Issue.record("timed out waiting for \(count) owned Agent sends")
    }

    private func makeServerTranscript(
        channels channelOverride: [SpiceChannelID]? = nil,
        agentConnected: UInt32 = 0,
        agentTokens: UInt32 = 0,
        supportedMouseModes: UInt32 = 3,
        currentMouseMode: UInt32 = 2,
        trailing: [Data] = []
    ) throws -> [Data] {
        let mainInit = SpiceMsgMainInit(
            sessionID: 77,
            displayChannelsHint: 1,
            supportedMouseModes: supportedMouseModes,
            currentMouseMode: currentMouseMode,
            agentConnected: agentConnected,
            agentTokens: agentTokens,
            multimediaTime: 0,
            ramHint: 0
        )
        let defaultChannels = [
            SpiceChannelID(type: 2, id: 0),
            SpiceChannelID(type: 3, id: 0),
            SpiceChannelID(type: 4, id: 0),
        ]
        let channels = SpiceMsgMainChannelsList(channels: channelOverride ?? defaultChannels)
        return try makeLinkResponses() + [
            try encodeMini(mainInit),
            try encodeMini(channels),
        ] + trailing
    }

    private func makeLinkResponses(
        mainCapabilities: [UInt32] = []
    ) throws -> [Data] {
        let reply = SpiceLinkReply(
            error: 0,
            publicKey: Data(repeating: 0, count: 162),
            commonCapabilityWordCount: 1,
            channelCapabilityWordCount: UInt32(mainCapabilities.count),
            capabilitiesOffset: UInt32(SpiceLinkReply.minimumWireSize)
        )
        var replyWriter = ByteWriter()
        try reply.encode(to: &replyWriter)
        replyWriter.writeUInt32LE(0b1011)
        for word in mainCapabilities {
            replyWriter.writeUInt32LE(word)
        }

        let linkHeader = SpiceLinkHeader(
            magic: SpiceProtocolConstants.magic,
            majorVersion: 2,
            minorVersion: 2,
            size: UInt32(replyWriter.data.count)
        )
        var linkHeaderWriter = ByteWriter()
        try linkHeader.encode(to: &linkHeaderWriter)

        var linkResultWriter = ByteWriter()
        try SpiceLinkResult(error: 0).encode(to: &linkResultWriter)

        return [
            linkHeaderWriter.data,
            replyWriter.data,
            linkResultWriter.data,
        ]
    }

    private func decodeLinkRequest(_ data: Data) throws -> SpiceLinkMessage {
        var reader = try ByteReader(data)
        _ = try SpiceLinkHeader.decode(from: &reader)
        return try SpiceLinkMessage.decode(from: &reader)
    }

    private func decodeMiniMessageID(_ data: Data) throws -> UInt16 {
        var reader = try ByteReader(data)
        return try reader.readUInt16LE()
    }

    private func inputButtonsState(_ data: Data, offset: Int) throws -> UInt16 {
        var reader = try ByteReader(data, offset: 6 + offset)
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

    private func readAgentMonitor(from reader: inout ByteReader) throws -> [Int64] {
        [
            Int64(try reader.readUInt32LE()),
            Int64(try reader.readUInt32LE()),
            Int64(try reader.readUInt32LE()),
            Int64(try reader.readInt32LE()),
            Int64(try reader.readInt32LE()),
        ]
    }

    private func decodedAgentMessages(_ outbound: [Data]) throws -> [VDAgentMessage] {
        let packets = try outbound.compactMap { packet -> Data? in
            guard packet.count >= 6, try decodeMiniMessageID(packet) == 107 else {
                return nil
            }
            return try decodeMiniBody(packet)
        }
        var decoder = VDAgentStreamDecoder()
        return try packets.flatMap { try decoder.append(packet: $0) }
    }

    private func encodeMini<Message: SpiceGeneratedMessage>(_ message: Message) throws -> Data {
        let id = try #require(Message.messageID)
        var bodyWriter = ByteWriter()
        try message.encode(to: &bodyWriter)
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(bodyWriter.data.count))
        writer.writeBytes(bodyWriter.data)
        return writer.data
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
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

    private func preparingOffer(_ event: SpiceSessionEvent?) -> SpiceMigrationOffer? {
        if case let .migration(.preparing(offer)) = event { return offer }
        return nil
    }
}

private final class TransportPool: Sendable {
    private let transports: Mutex<[any SpiceTransport]>

    init(_ transports: [any SpiceTransport]) {
        self.transports = Mutex(transports)
    }

    func take() -> any SpiceTransport {
        transports.withLock { transports in
            transports.removeFirst()
        }
    }
}

private actor MigrationEndGate {
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func intercept() async {
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor MigrationReplacementGate {
    private let failingKey: ChannelKey
    private var isBlocked = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    init(failingKey: ChannelKey) {
        self.failingKey = failingKey
    }

    func intercept(
        phase: SpiceSession.MigrationReplacementPhase,
        key: ChannelKey
    ) async throws {
        guard case .applying = phase, key == failingKey else { return }
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        throw ChannelError.invalidState
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseWithFailure() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor MigrationCompletionGate {
    private var didBlock = false
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func intercept(offerID: UInt64, operationID: UInt64) async {
        _ = offerID
        _ = operationID
        guard !didBlock else { return }
        didBlock = true
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        isBlocked = false
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor MigrationInputActivationGate {
    private var didBlock = false
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func intercept(
        phase: SpiceSession.MigrationReplacementPhase,
        key: ChannelKey
    ) async {
        guard case .applying = phase,
              key == ChannelKey(type: 3, id: 0),
              !didBlock else { return }
        didBlock = true
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        isBlocked = false
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor BlockingTransport: SpiceTransport {
    private let inbound: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let writeEvents: AsyncStream<Void>
    private let writeContinuation: AsyncStream<Void>.Continuation
    private(set) var outboundCount = 0
    private(set) var isClosed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let stream = AsyncStream.makeStream(of: Data.self)
        inbound = stream.stream
        continuation = stream.continuation
        let writes = AsyncStream.makeStream(of: Void.self)
        writeEvents = writes.stream
        writeContinuation = writes.continuation
    }

    func connect() async throws(TransportError) {}

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        for await data in inbound {
            return data
        }
        throw Task.isCancelled ? .cancelled : .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        outboundCount += 1
        writeContinuation.yield(())
    }

    func waitUntilFirstWrite() async {
        guard outboundCount == 0 else {
            return
        }
        for await _ in writeEvents {
            return
        }
    }

    func waitUntilClosed() async {
        guard !isClosed else { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    func close() async {
        isClosed = true
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        continuation.finish()
        writeContinuation.finish()
    }
}

private actor StreamingSessionTransport: SpiceTransport {
    private let inbound: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let writes: AsyncStream<Void>
    private let writeContinuation: AsyncStream<Void>.Continuation
    private(set) var outbound: [Data] = []
    private(set) var isConnected = false
    private var blockedAgentMessageTypes: Set<UInt32> = []
    private var blockAgentWritesAfterCount: Int?
    private var blockedAgentWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var blockedAgentWriteCount = 0
    private(set) var agentWriteCount = 0

    init(initial: [Data]) {
        let inboundPipe = AsyncStream.makeStream(of: Data.self)
        inbound = inboundPipe.stream
        inboundContinuation = inboundPipe.continuation
        for packet in initial {
            inboundPipe.continuation.yield(packet)
        }
        let writePipe = AsyncStream.makeStream(of: Void.self)
        writes = writePipe.stream
        writeContinuation = writePipe.continuation
    }

    func connect() async throws(TransportError) {
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard isConnected else {
            throw .connectionClosed
        }
        for await packet in inbound {
            guard packet.count <= maximum else {
                throw .connectionFailed("fixture exceeds requested maximum")
            }
            return packet
        }
        throw Task.isCancelled ? .cancelled : .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected else {
            throw .connectionClosed
        }
        let agentMessageType = Self.agentMessageType(in: data)
        let isAgentWirePacket = Self.isAgentWirePacket(data)
        if (agentMessageType.map { blockedAgentMessageTypes.contains($0) } == true)
            || (isAgentWirePacket
                && blockAgentWritesAfterCount.map { agentWriteCount >= $0 } == true) {
            blockedAgentWriteCount += 1
            await withCheckedContinuation { continuation in
                blockedAgentWriteWaiters.append(continuation)
            }
            guard isConnected else { throw .connectionClosed }
        }
        outbound.append(data)
        if isAgentWirePacket {
            agentWriteCount += 1
        }
        writeContinuation.yield(())
    }

    func enqueue(_ data: Data) {
        inboundContinuation.yield(data)
    }

    func waitForOutboundCount(_ count: Int) async {
        guard outbound.count < count else {
            return
        }
        for await _ in writes {
            if outbound.count >= count {
                return
            }
        }
    }

    func waitUntilDisconnected(maximumYields: Int = 10_000) async -> Bool {
        for _ in 0..<maximumYields {
            if !isConnected { return true }
            await Task.yield()
        }
        return !isConnected
    }

    func blockAgentMessages(types: Set<UInt32>) {
        blockedAgentMessageTypes = types
    }

    func blockAgentWrites(afterWrittenCount count: Int) {
        blockAgentWritesAfterCount = max(0, count)
    }

    func waitForBlockedAgentWriteCount(_ count: Int) async {
        while blockedAgentWriteCount < count {
            await Task.yield()
        }
    }

    func releaseBlockedAgentWrites() {
        blockedAgentMessageTypes.removeAll(keepingCapacity: false)
        blockAgentWritesAfterCount = nil
        let waiters = blockedAgentWriteWaiters
        blockedAgentWriteWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    func close() async {
        isConnected = false
        releaseBlockedAgentWrites()
        inboundContinuation.finish()
        writeContinuation.finish()
    }

    private nonisolated static func agentMessageType(in packet: Data) -> UInt32? {
        guard packet.count >= 14,
              packet[packet.startIndex] == UInt8(SpiceMainAgentWire.clientData & 0xff),
              packet[packet.startIndex + 1]
                == UInt8((SpiceMainAgentWire.clientData >> 8) & 0xff) else {
            return nil
        }
        let start = packet.startIndex + 10
        return UInt32(packet[start])
            | (UInt32(packet[start + 1]) << 8)
            | (UInt32(packet[start + 2]) << 16)
            | (UInt32(packet[start + 3]) << 24)
    }

    private nonisolated static func isAgentWirePacket(_ packet: Data) -> Bool {
        guard packet.count >= 2 else { return false }
        return packet[packet.startIndex] == UInt8(SpiceMainAgentWire.clientData & 0xff)
            && packet[packet.startIndex + 1]
                == UInt8((SpiceMainAgentWire.clientData >> 8) & 0xff)
    }
}

private actor BlockingCloseSessionTransport: SpiceTransport {
    private let inbound: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isConnected = false
    private var closeStarted = false

    init(initial: [Data]) {
        let inboundPipe = AsyncStream.makeStream(of: Data.self)
        inbound = inboundPipe.stream
        inboundContinuation = inboundPipe.continuation
        for packet in initial {
            inboundPipe.continuation.yield(packet)
        }
    }

    func connect() async throws(TransportError) {
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard isConnected else { throw .connectionClosed }
        for await packet in inbound {
            guard packet.count <= maximum else {
                throw .connectionFailed("fixture exceeds requested maximum")
            }
            return packet
        }
        throw Task.isCancelled ? .cancelled : .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected else { throw .connectionClosed }
    }

    func waitUntilCloseStarts() async {
        guard !closeStarted else { return }
        await withCheckedContinuation { continuation in
            closeStartWaiters.append(continuation)
        }
    }

    func completeClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }

    func close() async {
        guard !closeStarted else { return }
        closeStarted = true
        let waiters = closeStartWaiters
        closeStartWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            closeContinuation = continuation
        }
        isConnected = false
        inboundContinuation.finish()
    }
}

private actor FailingStreamingSessionTransport: SpiceTransport {
    private let inbound: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let failingWrites: Set<Int>
    private(set) var outbound: [Data] = []
    private var writeCount = 0
    private var isConnected = false

    init(initial: [Data], failingWrites: Set<Int>) {
        let inboundPipe = AsyncStream.makeStream(of: Data.self)
        inbound = inboundPipe.stream
        inboundContinuation = inboundPipe.continuation
        for packet in initial {
            inboundPipe.continuation.yield(packet)
        }
        self.failingWrites = failingWrites
    }

    func connect() async throws(TransportError) {
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard isConnected else { throw .connectionClosed }
        for await packet in inbound {
            guard packet.count <= maximum else {
                throw .connectionFailed("fixture exceeds requested maximum")
            }
            return packet
        }
        throw Task.isCancelled ? .cancelled : .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected else { throw .connectionClosed }
        writeCount += 1
        if failingWrites.contains(writeCount) {
            throw .connectionFailed("fixture write \(writeCount)")
        }
        outbound.append(data)
    }

    func close() async {
        isConnected = false
        inboundContinuation.finish()
    }
}

private actor BlockingEventSessionTransport: SpiceTransport {
    private let inbound: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private var eventWriteCompletion: CheckedContinuation<Void, Never>?
    private var eventWriteStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var outbound: [Data] = []
    private var writeCount = 0
    private var isConnected = false
    private(set) var isClosed = false

    init(initial: [Data]) {
        let inboundPipe = AsyncStream.makeStream(of: Data.self)
        inbound = inboundPipe.stream
        inboundContinuation = inboundPipe.continuation
        for packet in initial {
            inboundPipe.continuation.yield(packet)
        }
    }

    func connect() async throws(TransportError) {
        guard !isClosed else { throw .connectionClosed }
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard isConnected else { throw .connectionClosed }
        for await packet in inbound {
            guard packet.count <= maximum else {
                throw .connectionFailed("fixture exceeds requested maximum")
            }
            return packet
        }
        throw Task.isCancelled ? .cancelled : .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected else { throw .connectionClosed }
        writeCount += 1
        if writeCount == 4 {
            let waiters = eventWriteStartWaiters
            eventWriteStartWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                eventWriteCompletion = continuation
            }
        }
        outbound.append(data)
    }

    func waitUntilEventWriteStarts() async {
        guard writeCount < 4 else { return }
        await withCheckedContinuation { continuation in
            eventWriteStartWaiters.append(continuation)
        }
    }

    func enqueue(_ data: Data) {
        inboundContinuation.yield(data)
    }

    func completeEventWrite() {
        eventWriteCompletion?.resume()
        eventWriteCompletion = nil
    }

    func close() async {
        isClosed = true
        isConnected = false
        completeEventWrite()
        for waiter in eventWriteStartWaiters { waiter.resume() }
        eventWriteStartWaiters.removeAll(keepingCapacity: false)
        inboundContinuation.finish()
    }
}

private struct SessionTicketEncryptor: TicketEncrypting {
    func encryptTicket(
        password: consuming Data,
        publicKeyDER: Data
    ) throws(AuthenticationError) -> Data {
        #expect(password == Data("secret".utf8))
        #expect(publicKeyDER.count == 162)
        return Data(repeating: 0x5a, count: 128)
    }
}

private actor ControlledMigrationExecutor: SpiceMigrationHandoffExecuting {
    private var preparationContinuations:
        [UInt64: CheckedContinuation<Bool, any Error>] = [:]
    private var preparingIDs: Set<UInt64> = []
    private var cancelledIDs: Set<UInt64> = []
    private var preparingWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var committedOffers: [SpiceMigrationOffer] = []

    func prepare(_ offer: SpiceMigrationOffer) async throws -> Bool {
        preparingIDs.insert(offer.id)
        for waiter in preparingWaiters.removeValue(forKey: offer.id) ?? [] {
            waiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            preparationContinuations[offer.id] = continuation
        }
    }

    func commit(_ offer: SpiceMigrationOffer) async throws {
        committedOffers.append(offer)
    }

    func switchHost(_ offer: SpiceMigrationOffer) async throws {
        committedOffers.append(offer)
    }

    func cancel(_ offer: SpiceMigrationOffer) {
        cancelledIDs.insert(offer.id)
        preparationContinuations.removeValue(forKey: offer.id)?.resume(
            throwing: CancellationError()
        )
        for waiter in cancellationWaiters.removeValue(forKey: offer.id) ?? [] {
            waiter.resume()
        }
    }

    func completePreparation(_ id: UInt64, seamless: Bool) {
        preparationContinuations.removeValue(forKey: id)?.resume(returning: seamless)
    }

    func waitUntilPreparing(_ id: UInt64) async {
        guard !preparingIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            preparingWaiters[id, default: []].append(continuation)
        }
    }

    func waitUntilCancelled(_ id: UInt64) async {
        guard !cancelledIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[id, default: []].append(continuation)
        }
    }
}

private actor NonCooperativeMigrationExecutor: SpiceMigrationHandoffExecuting {
    private var preparationContinuations:
        [UInt64: CheckedContinuation<Bool, any Error>] = [:]
    private var preparingIDs: Set<UInt64> = []
    private var cancelledTaskIDs: Set<UInt64> = []
    private var preparingWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    func prepare(_ offer: SpiceMigrationOffer) async throws -> Bool {
        preparingIDs.insert(offer.id)
        for waiter in preparingWaiters.removeValue(forKey: offer.id) ?? [] {
            waiter.resume()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                preparationContinuations[offer.id] = continuation
            }
        } onCancel: {
            Task { await self.recordTaskCancellation(offer.id) }
        }
    }

    func commit(_ offer: SpiceMigrationOffer) async throws {}
    func switchHost(_ offer: SpiceMigrationOffer) async throws {}

    func cancel(_ offer: SpiceMigrationOffer) {
        // Deliberately does not finish prepare. The fixture distinguishes the
        // coordinator's semantic cancel callback from cancellation of the
        // Session-owned Task slot.
    }

    func completePreparation(_ id: UInt64, seamless: Bool) {
        preparationContinuations.removeValue(forKey: id)?.resume(returning: seamless)
    }

    func waitUntilPreparing(_ id: UInt64) async {
        guard !preparingIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            preparingWaiters[id, default: []].append(continuation)
        }
    }

    func waitUntilTaskCancelled(_ id: UInt64) async {
        guard !cancelledTaskIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[id, default: []].append(continuation)
        }
    }

    func finishAllPreparations() {
        let continuations = preparationContinuations.values
        preparationContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func recordTaskCancellation(_ id: UInt64) {
        cancelledTaskIDs.insert(id)
        for waiter in cancellationWaiters.removeValue(forKey: id) ?? [] {
            waiter.resume()
        }
    }
}
