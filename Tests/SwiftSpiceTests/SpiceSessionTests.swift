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

        let activeDiagnostics = await session.diagnosticsSnapshot()
        requireSendable(activeDiagnostics)
        #expect(activeDiagnostics == activeDiagnostics)
        #expect(activeDiagnostics.displayChannelCount == 1)

        session.presentationDiagnostics.recordMetalPresentedFrame()
        session.presentationDiagnostics.recordCPUFallback(.textureCreationFailed)
        let presentationDiagnostics = await session.diagnosticsSnapshot()
        #expect(presentationDiagnostics.metalPresentedFrames == 1)
        #expect(presentationDiagnostics.cpuFallbackFrames == 1)
        #expect(presentationDiagnostics.textureCreationFailedFallbackFrames == 1)
        #expect(presentationDiagnostics.lastCPUFallbackReason == .textureCreationFailed)

        await session.disconnect()
        #expect(await mainTransport.isClosed)
        #expect(await displayTransport.isClosed)
        #expect(await inputsTransport.isClosed)
        let cursorTransportIsClosed = await cursorTransport.isClosed
        #expect(cursorTransportIsClosed)

        let retiredDiagnostics = await session.diagnosticsSnapshot()
        #expect(retiredDiagnostics.displayChannelCount == 1)

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
        let diagnostics = await manager.diagnosticsSnapshot()
        #expect(diagnostics.capabilityAnnouncementsAttempted == 1)
        #expect(diagnostics.capabilityAnnouncementsSent == 1)
        #expect(diagnostics.capabilityAnnouncementFailures == 0)
        #expect(diagnostics.inboundMessages == 1)
        #expect(diagnostics.inboundCurrentProtocolMessages == 1)
        #expect(diagnostics.inboundUnexpectedProtocolMessages == 0)
        #expect(diagnostics.inboundCapabilityAnnouncements == 0)
        #expect(diagnostics.inboundMonitorReplies == 1)
        #expect(diagnostics.inboundDecodeFailures == 0)
        #expect(diagnostics.lastInboundProtocolID == VDAgentMessage.protocolVersion)
        #expect(diagnostics.lastInboundMessageType == VDAgentMessageType.reply.rawValue)
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
        let diagnostics = await manager.diagnosticsSnapshot()
        #expect(diagnostics.capabilityAnnouncementsAttempted == 1)
        #expect(diagnostics.capabilityAnnouncementsSent == 1)
        #expect(diagnostics.inboundMessages == 1)
        #expect(diagnostics.inboundCapabilityAnnouncements == 1)
        #expect(diagnostics.inboundClipboardMessages == 0)
        #expect(diagnostics.peerLegacyClipboardCapability == true)
        #expect(diagnostics.peerClipboardByDemandCapability == true)
        #expect(diagnostics.inboundOtherMessages == 0)
        #expect(diagnostics.lastInboundProtocolID == VDAgentMessage.protocolVersion)
        #expect(
            diagnostics.lastInboundMessageType
                == VDAgentMessageType.announceCapabilities.rawValue
        )

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

    @Test func agentManagerClassifiesClipboardWireFailuresWithoutContent() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 16
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
        var events = manager.events.makeAsyncIterator()

        func enqueue(_ command: VDAgentClipboardCommand) async throws {
            let message = try VDAgentClipboardCodec.encode(command)
            let packet = try #require(VDAgentWireEncoder.fragments(for: message).first)
            await transport.enqueue(encodeMini(id: 109, body: packet))
        }

        let legacyClipboard = VDAgentCapabilities(words: [
            UInt32(1) << UInt32(VDAgentCapability.clipboard.rawValue),
        ])
        try await enqueue(.announceCapabilities(
            requestReply: false,
            capabilities: legacyClipboard
        ))

        let notReadyCommands: [VDAgentClipboardCommand] = [
            .data(type: VDAgentClipboardType.utf8Text.rawValue, data: Data("private".utf8)),
            .grab(types: [VDAgentClipboardType.utf8Text.rawValue]),
            .request(type: VDAgentClipboardType.utf8Text.rawValue),
            .release,
        ]
        for command in notReadyCommands {
            try await enqueue(command)
            #expect(await events.next() == .failed(.invalidAgentMessage(
                "clipboard message before capability negotiation"
            )))
        }

        let legacyDiagnostics = await manager.diagnosticsSnapshot()
        #expect(legacyDiagnostics.peerLegacyClipboardCapability == true)
        #expect(legacyDiagnostics.peerClipboardByDemandCapability == false)
        #expect(legacyDiagnostics.clipboardFailures == 4)
        #expect(legacyDiagnostics.lastClipboardFailureCategory == .clipboardNotReady)

        try await enqueue(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        #expect(await events.next() == .ready)
        try await enqueue(.data(
            type: VDAgentClipboardType.utf8Text.rawValue,
            data: Data("also private".utf8)
        ))
        #expect(await events.next() == .failed(.invalidAgentMessage(
            "unsolicited clipboard data"
        )))

        let diagnostics = await manager.diagnosticsSnapshot()
        #expect(diagnostics.inboundMessages == 7)
        #expect(diagnostics.inboundCapabilityAnnouncements == 2)
        #expect(diagnostics.inboundClipboardMessages == 5)
        #expect(diagnostics.inboundClipboardDataMessages == 2)
        #expect(diagnostics.inboundClipboardGrabMessages == 1)
        #expect(diagnostics.inboundClipboardRequestMessages == 1)
        #expect(diagnostics.inboundClipboardReleaseMessages == 1)
        #expect(diagnostics.peerLegacyClipboardCapability == true)
        #expect(diagnostics.peerClipboardByDemandCapability == true)
        #expect(diagnostics.clipboardFailures == 5)
        #expect(diagnostics.lastClipboardFailureCategory == .unsolicitedData)
        #expect(diagnostics.inboundDecodeFailures == 0)

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
        // Runtime mouse-mode renegotiation adds a target-side
        // MAIN_MOUSE_MODE_REQUEST before the final MIGRATE_END acknowledgement.
        await target.waitForOutboundCount(5)
        let targetOutbound = await target.outbound
        #expect(try targetOutbound.suffix(2).map(decodeMiniMessageID) == [109, 105])
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

    @Test func seamlessTargetNegotiatesBeforeReportingReady() async throws {
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
        #expect(offer.mode == .seamless(sourceVersion: 9))
        #expect(await events.next() == .migration(.ready(offer, seamless: true)))

        try await session.send(.mousePress(.left))
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
        #expect(!(await source.isConnected))
        #expect(!(await sourceInputs.isConnected))
        #expect(await target.isConnected)
        #expect(await targetInputs.isConnected)

        let targetInputCount = await targetInputs.outbound.count
        try await session.send(.mousePosition(x: 40, y: 50, displayID: 0))
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

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
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

private actor BlockingTransport: SpiceTransport {
    private let inbound: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let writeEvents: AsyncStream<Void>
    private let writeContinuation: AsyncStream<Void>.Continuation
    private(set) var outboundCount = 0
    private(set) var isClosed = false

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
        while !isClosed {
            await Task.yield()
        }
    }

    func close() async {
        isClosed = true
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
        outbound.append(data)
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

    func close() async {
        isConnected = false
        inboundContinuation.finish()
        writeContinuation.finish()
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
