import Foundation
import SpiceTestSupport
import SpiceTransport
import Synchronization
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceRenderer
@testable import SpiceWire
@testable import SwiftSpice

@Suite("SpiceSession bootstrap")
struct SpiceSessionTests {
    enum ConnectionCancellation: String, Sendable {
        case task
        case disconnect
    }

    enum MigrationPreparationTermination: String, Sendable {
        case failure
        case cancellation
    }

    @Test func fullAgentBufferRetainsReconnectLifecycleBoundaries() async {
        let mailbox = SpiceAgentEventMailbox(capacity: 4)
        let stale = SpiceAgentMessage(protocolID: 1, type: 2, opaque: 3, data: Data([4]))
        #expect(mailbox.send(.message(stale)) == .enqueued)
        #expect(mailbox.send(.message(stale)) == .enqueued)
        #expect(mailbox.send(.message(stale)) == .enqueued)
        #expect(mailbox.send(.message(stale)) == .enqueued)
        #expect(mailbox.send(.message(stale)) == .full)
        mailbox.sendLifecycle(.disconnected(errorCode: 0), disconnectRevision: 7)
        mailbox.sendLifecycle(.connected)

        let disconnected = await mailbox.next()
        #expect(disconnected?.event == .disconnected(errorCode: 0))
        #expect(disconnected?.disconnectRevision == 7)
        #expect((await mailbox.next())?.event == .connected)
        mailbox.finish()
    }

    @Test func cancelledAgentConsumerCanBeReplacedWithoutReportingOverflow() async {
        let mailbox = SpiceAgentEventMailbox(capacity: 2)
        let message = SpiceAgentMessage(
            protocolID: 1,
            type: 2,
            opaque: 3,
            data: Data([4])
        )
        #expect(mailbox.send(.message(message)) == .enqueued)
        let gate = AgentMessageProcessingGate()
        let consumer = Task {
            await gate.block()
            return await mailbox.next()
        }
        await gate.waitUntilEntered()
        consumer.cancel()
        await gate.release()
        #expect(await consumer.value == nil)
        #expect(mailbox.send(.message(message)) == .enqueued)
        #expect(mailbox.send(.message(message)) == .terminated)

        #expect((await mailbox.next())?.event == .message(message))
        #expect((await mailbox.next())?.event == .message(message))
        #expect(mailbox.send(.message(message)) == .enqueued)
        mailbox.finish()
    }

    @Test func seamlessMigrationPreservesStaticDesktopWithoutNewDamage() async throws {
        let source = SpiceDesktopSource()
        source.beginSession(pointerMode: .absolute)
        let subscription = source.subscribe()
        subscription.setDemand(.visible)
        defer { subscription.cancel() }
        var updates = subscription.updates.makeAsyncIterator()
        _ = await updates.next()

        source.receiveFrame(FrameSnapshot(
            surfaceID: 0,
            width: 2,
            height: 1,
            bytesPerRow: 8,
            lifecycleGeneration: 4,
            revision: 9,
            pixels: Data([1, 2, 3, 255, 4, 5, 6, 255]),
            ioSurfaceFrame: nil
        ), displayChannelID: 0)
        let before = try #require(await updates.next())

        // A seamless target reuses the active DisplayChannel and SurfaceStore;
        // no create/draw command is required after the connection handoff.
        source.beginSeamlessMigration(pointerMode: .relative)
        let after = try #require(await updates.next())

        #expect(after.generation > before.generation)
        #expect(after.pointerMode == .relative)
        #expect(after.frame?.revision == before.frame?.revision)
        #expect(after.frame?.frame.pixels == before.frame?.frame.pixels)
        #expect(after.frame?.damage == .full)
    }

    @Test func preservesStructuredVideoCodecFailures() {
        #expect(SpiceSession.map(channelError: .videoCodecFailure(
            codec: .h264,
            reason: .hardwareUnavailable(status: -12_950)
        )) == .videoCodecUnavailable(SpiceVideoCodecFailure(
            codec: .h264,
            reason: .hardwareUnavailable(status: -12_950)
        )))
        #expect(SpiceSession.map(channelError: .videoCodecFailure(
            codec: .h265,
            reason: .unsupportedFormat(status: -12_909)
        )) == .videoCodecUnavailable(SpiceVideoCodecFailure(
            codec: .h265,
            reason: .unsupportedFormat(status: -12_909)
        )))
    }

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
        let desktop = session.desktop.subscribe()
        let pointerModes = Mutex<[SpicePointerMode]>([])
        desktop.setUpdateHandler { snapshot in
            pointerModes.withLock { $0.append(snapshot.pointerMode) }
        }
        desktop.setDemand(.visible)

        let info = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        #expect(info.supportedMouseModes == 3)
        #expect(info.currentMouseMode == 1)
        for _ in 0..<1_000 {
            if await transport.outbound.count >= 5 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let outbound = await transport.outbound
        try #require(outbound.count >= 5)
        #expect(try decodeMiniMessageID(outbound[3]) == 105)
        #expect(try decodeMiniBody(outbound[3]) == Data([0x02, 0x00]))
        #expect(try decodeMiniMessageID(outbound[4]) == 104)
        #expect(pointerModes.withLock { $0.last } == .relative)

        let absoluteBaseline = pointerModes.withLock(\.count)
        await transport.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 2)
        ))
        for _ in 0..<1_000 {
            if pointerModes.withLock({ $0.count > absoluteBaseline }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(pointerModes.withLock { $0.count } == absoluteBaseline + 1)
        #expect(pointerModes.withLock { $0.last } == .absolute)

        let relativeBaseline = pointerModes.withLock(\.count)
        await transport.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 1)
        ))
        for _ in 0..<1_000 {
            if pointerModes.withLock({ $0.count > relativeBaseline }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(pointerModes.withLock { $0.count } == relativeBaseline + 1)
        #expect(pointerModes.withLock { $0.last } == .relative)
        desktop.cancel()
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
        let desktop = session.desktop.subscribe()
        desktop.setDemand(.visible)
        let desktopTask = Task {
            var iterator = desktop.updates.makeAsyncIterator()
            return [await iterator.next(), await iterator.next()]
        }
        let eventTask = Task {
            var iterator = session.events.makeAsyncIterator()
            return await iterator.next()
        }

        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )

        let desktopSnapshots = await desktopTask.value.compactMap { $0 }
        #expect(desktopSnapshots.last?.pointerMode == .absolute)
        guard case .failed = await eventTask.value else {
            Issue.record("expected supervised Main failure")
            return
        }
        desktop.cancel()
        #expect(await mainTransport.isClosed)
    }

    @Test func connectsDiscoversChannelsAndDisconnects() async throws {
        let mainTransport = StreamingSessionTransport(
            initial: try makeServerTranscript()
        )
        let displayTransport = StreamingSessionTransport(
            initial: try makeLinkResponses()
        )
        let inputsTransport = StreamingSessionTransport(
            initial: try makeLinkResponses()
        )
        let cursorTransport = StreamingSessionTransport(
            initial: try makeLinkResponses()
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

        session.presentationDiagnostics.recordMetalPresentedFrame(isAdvancedVideo: true)
        session.presentationDiagnostics.recordCPUFallback(.textureCreationFailed)
        let presentationDiagnostics = await session.diagnosticsSnapshot()
        #expect(presentationDiagnostics.metalPresentedFrames == 1)
        #expect(presentationDiagnostics.advancedVideoPresentedFrames == 1)
        #expect(presentationDiagnostics.cpuFallbackFrames == 1)
        #expect(presentationDiagnostics.textureCreationFailedFallbackFrames == 1)
        #expect(presentationDiagnostics.lastCPUFallbackReason == .textureCreationFailed)

        await session.disconnect()
        #expect(!(await mainTransport.isConnected))
        #expect(!(await displayTransport.isConnected))
        #expect(!(await inputsTransport.isConnected))
        #expect(!(await cursorTransport.isConnected))

        let retiredDiagnostics = await session.diagnosticsSnapshot()
        #expect(retiredDiagnostics.displayChannelCount == 1)

        let displayLink = try decodeLinkRequest(try #require(await displayTransport.outbound.first))
        #expect(displayLink.connectionID == 77)
        #expect(displayLink.channelType == 2)
        let inputsLink = try decodeLinkRequest(try #require(await inputsTransport.outbound.first))
        #expect(inputsLink.connectionID == 77)
        #expect(inputsLink.channelType == 3)
    }

    @Test(arguments: [4, 5])
    func childConnectionsUseWidthFourAndPreserveDescriptorOrder(
        _ childCount: Int
    ) async throws {
        let descriptors = displayChannelIDs(count: childCount)
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: descriptors
        ))
        let probe = BoundedChildConnectProbe()
        let children = try gatedChildTransports(count: childCount, probe: probe)
        let session = SpiceSession(
            transportFactory: transportFactory(main: main, children: children),
            ticketEncryptor: SessionTicketEncryptor()
        )

        let connection = Task {
            try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        await probe.waitUntilStarted(count: min(childCount, 4))
        #expect(await probe.peakActiveCount == min(childCount, 4))
        #expect(await probe.activeCount == min(childCount, 4))
        #expect(await probe.startedIDs.count == min(childCount, 4))

        if childCount == 5 {
            await probe.succeed(id: 3)
            await probe.waitUntilStarted(count: 5)
            #expect(await probe.peakActiveCount == 4)
            #expect(await probe.activeCount == 4)
            for id in [1, 4, 0, 2] {
                await probe.succeed(id: id)
            }
        } else {
            for id in [3, 1, 0, 2] {
                await probe.succeed(id: id)
            }
        }

        let info = try await connection.value
        #expect(info.channels == descriptors.map {
            SpiceChannelDescriptor(type: $0.type, id: $0.id)
        })
        #expect((await session.diagnosticsSnapshot()).displayChannelCount == childCount)
        var linkedKeys: [ChannelKey] = []
        for child in children {
            let request = try decodeLinkRequest(try #require(await child.outbound.first))
            linkedKeys.append(ChannelKey(type: request.channelType, id: request.channelID))
        }
        #expect(Set(linkedKeys) == Set(descriptors.map {
            ChannelKey(type: $0.type, id: $0.id)
        }))

        await session.disconnect()
        for child in children {
            #expect(await child.isClosed)
            #expect(!(await child.isConnected))
        }
    }

    @Test func duplicateChildDescriptorFailsBeforeAnyChildTransportConnects() async throws {
        let descriptors = [
            SpiceChannelID(type: 2, id: 0),
            SpiceChannelID(type: 3, id: 0),
            SpiceChannelID(type: 2, id: 0),
        ]
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: descriptors
        ))
        let probe = BoundedChildConnectProbe()
        let children = try gatedChildTransports(count: descriptors.count, probe: probe)
        let session = SpiceSession(
            transportFactory: transportFactory(main: main, children: children),
            ticketEncryptor: SessionTicketEncryptor()
        )

        await #expect(throws: SpiceError.protocolError(
            "duplicate channel type=2 id=0"
        )) {
            try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        #expect(await probe.startedIDs.isEmpty)
        for child in children {
            #expect(await child.connectCallCount == 0)
            #expect(!(await child.isConnected))
        }
        #expect(!(await main.isConnected))
    }

    @Test func firstChildFailureDrainsLateSuccessAndClosesEveryStartedTransport() async throws {
        let descriptors = displayChannelIDs(count: 6)
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: descriptors
        ))
        let probe = BoundedChildConnectProbe()
        let children = try gatedChildTransports(
            count: descriptors.count,
            probe: probe,
            ignoresCancellationIDs: [4]
        )
        let session = SpiceSession(
            transportFactory: transportFactory(main: main, children: children),
            ticketEncryptor: SessionTicketEncryptor()
        )
        let connection = Task {
            try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }

        await probe.waitUntilStarted(count: 4)
        await probe.succeed(id: 0)
        await probe.waitUntilStarted(count: 5)
        await probe.fail(id: 1)
        await probe.waitUntilActiveCount(1)
        #expect(await probe.startedIDs.count == 5)
        #expect(await probe.activeCount == 1)
        await probe.succeed(id: 4)

        await #expect(throws: SpiceError.connectionFailed(
            "connectionFailed(\"injected child connect failure\")"
        )) {
            try await connection.value
        }
        #expect(await probe.activeCount == 0)
        #expect(!(await main.isConnected))
        for child in children.prefix(5) {
            #expect(await child.isClosed)
            #expect(!(await child.isConnected))
        }
        #expect(await children[5].connectCallCount == 0)
        #expect(!(await children[5].isConnected))
    }

    @Test(arguments: [ConnectionCancellation.task, .disconnect])
    func cancellingInitialChildPreparationLeavesNoActiveTransport(
        _ cancellation: ConnectionCancellation
    ) async throws {
        let descriptors = displayChannelIDs(count: 5)
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: descriptors
        ))
        let probe = BoundedChildConnectProbe()
        let children = try gatedChildTransports(count: descriptors.count, probe: probe)
        let session = SpiceSession(
            transportFactory: transportFactory(main: main, children: children),
            ticketEncryptor: SessionTicketEncryptor()
        )
        let connection = Task {
            try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        await probe.waitUntilStarted(count: 4)

        let disconnect: Task<Void, Never>?
        switch cancellation {
        case .task:
            connection.cancel()
            disconnect = nil
        case .disconnect:
            disconnect = Task { await session.disconnect() }
        }
        await #expect(throws: SpiceError.cancelled) {
            try await connection.value
        }
        await disconnect?.value
        await probe.waitUntilActiveCount(0)

        #expect(await probe.peakActiveCount == 4)
        #expect(await probe.startedIDs.count == 4)
        #expect(await probe.activeCount == 0)
        #expect(!(await main.isConnected))
        for child in children.prefix(4) {
            #expect(await child.isClosed)
            #expect(!(await child.isConnected))
        }
        #expect(await children[4].connectCallCount == 0)
        #expect(!(await children[4].isConnected))
    }

    @Test func migrationChildConnectionsUseWidthFourAndStableDescriptorOrder() async throws {
        let descriptors = displayChannelIDs(count: 5)
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: descriptors
        ))
        let sourceChildren = try streamingChildTransports(count: descriptors.count)
        let target = StreamingSessionTransport(initial: try makeLinkResponses())
        let probe = BoundedChildConnectProbe()
        let targetChildren = try gatedChildTransports(
            count: descriptors.count,
            probe: probe
        )
        var transports: [any SpiceTransport] = [source]
        transports.append(contentsOf: sourceChildren)
        transports.append(target)
        transports.append(contentsOf: targetChildren)
        let session = SpiceSession(
            transportFactory: transportFactory(transports),
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()

        await source.enqueue(encodeMini(id: 101, body: migrationDestinationBody(
            host: "bounded-target.example"
        )))
        let offer = try #require(preparingOffer(await events.next()))
        await probe.waitUntilStarted(count: 4)
        #expect(await probe.peakActiveCount == 4)
        #expect(await probe.startedIDs.count == 4)
        await probe.succeed(id: 2)
        await probe.waitUntilStarted(count: 5)
        for id in [4, 1, 3, 0] {
            await probe.succeed(id: id)
        }

        #expect(await events.next() == .migration(.ready(offer, seamless: false)))
        #expect(await probe.peakActiveCount == 4)
        #expect(await probe.activeCount == 0)
        var linkedKeys: [ChannelKey] = []
        for child in targetChildren {
            let request = try decodeLinkRequest(try #require(await child.outbound.first))
            linkedKeys.append(ChannelKey(type: request.channelType, id: request.channelID))
        }
        #expect(Set(linkedKeys) == Set(descriptors.map {
            ChannelKey(type: $0.type, id: $0.id)
        }))
        #expect(await source.isConnected)

        await source.enqueue(encodeMini(id: 102, body: Data()))
        #expect(await events.next() == .migration(.cancelled(offer)))
        await target.waitUntilClosed()
        #expect(!(await target.isConnected))
        for child in targetChildren {
            await child.waitUntilClosed()
            #expect(await child.isClosed)
            #expect(!(await child.isConnected))
        }
        await session.disconnect()
    }

    @Test(arguments: [
        MigrationPreparationTermination.failure,
        .cancellation,
    ])
    func migrationChildFailureOrCancellationLeavesSourceAndNoTargetLeak(
        _ termination: MigrationPreparationTermination
    ) async throws {
        let descriptors = displayChannelIDs(count: 5)
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: descriptors
        ))
        let sourceChildren = try streamingChildTransports(count: descriptors.count)
        let target = StreamingSessionTransport(initial: try makeLinkResponses())
        let probe = BoundedChildConnectProbe()
        let targetChildren = try gatedChildTransports(
            count: descriptors.count,
            probe: probe,
            ignoresCancellationIDs: termination == .failure ? [3] : []
        )
        var transports: [any SpiceTransport] = [source]
        transports.append(contentsOf: sourceChildren)
        transports.append(target)
        transports.append(contentsOf: targetChildren)
        let session = SpiceSession(
            transportFactory: transportFactory(transports),
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var events = session.events.makeAsyncIterator()

        await source.enqueue(encodeMini(id: 101, body: migrationDestinationBody(
            host: "terminating-target.example"
        )))
        let offer = try #require(preparingOffer(await events.next()))
        await probe.waitUntilStarted(count: 4)
        switch termination {
        case .failure:
            await probe.fail(id: 0, reason: "migration child failed")
            await probe.waitUntilActiveCount(1)
            await probe.succeed(id: 3)
            guard case let .migration(.failed(failedOffer, reason)) = await events.next()
            else {
                Issue.record("expected migration preparation failure")
                return
            }
            #expect(failedOffer == offer)
            #expect(reason.contains("migration child failed"))
        case .cancellation:
            await source.enqueue(encodeMini(id: 102, body: Data()))
            #expect(await events.next() == .migration(.cancelled(offer)))
        }
        await probe.waitUntilActiveCount(0)
        await target.waitUntilClosed()

        #expect(await probe.peakActiveCount == 4)
        #expect(await probe.startedIDs.count == 4)
        #expect(await probe.activeCount == 0)
        #expect(await targetChildren[4].connectCallCount == 0)
        #expect(!(await target.isConnected))
        for child in targetChildren.prefix(4) {
            await child.waitUntilClosed()
            #expect(await child.isClosed)
            #expect(!(await child.isConnected))
        }
        #expect(await source.isConnected)
        for child in sourceChildren {
            #expect(await child.isConnected)
        }
        await session.disconnect()
    }

    @Test func publishesAgentEventsOnDedicatedStream() async throws {
        let agentMessage = VDAgentMessage(
            protocolID: 1,
            type: 6,
            opaque: 11,
            data: Data("agent".utf8)
        )
        let encoded = try #require(VDAgentWireEncoder.fragments(for: agentMessage).first)
        let transport = StreamingSessionTransport(
            initial: try makeServerTranscript(channels: [])
        )
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        var iterator = session.agentEvents.makeAsyncIterator()

        let info = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        #expect(!info.agentConnected)
        await transport.enqueue(encodeMini(id: 115, body: uint32(2)))
        #expect(await iterator.next() == .connected)
        await transport.enqueue(encodeMini(id: 109, body: encoded))
        #expect(await iterator.next() == .message(SpiceAgentMessage(
            protocolID: 1,
            type: 6,
            opaque: 11,
            data: Data("agent".utf8)
        )))
        await transport.enqueue(encodeMini(id: 108, body: uint32(9)))
        #expect(await iterator.next() == .disconnected(errorCode: 9))
        await session.disconnect()
    }

    @Test func disconnectClosesSessionImageCacheAndWakesPendingDisplayResolve() async throws {
        let displayChannel = [SpiceChannelID(type: 2, id: 0)]
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: displayChannel
        ))
        let display = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([main, display])
        let imageCache = DisplayImageCache()
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            imageCacheFactory: { imageCache }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        await display.waitForOutboundCount(4)
        await display.enqueue(try encodeMini(SpiceMsgDisplaySurfaceCreate(
            surfaceID: 1,
            width: 2,
            height: 1,
            format: 32,
            flags: 1
        )))
        await display.enqueue(encodeMini(id: 304, body: sessionCachedCopyBody(
            descriptorID: 0xc001
        )))
        for _ in 0..<1_000 {
            if await imageCache.diagnosticsSnapshot().pendingWaiterCount == 1 { break }
            await Task.yield()
        }
        #expect(await imageCache.diagnosticsSnapshot().pendingWaiterCount == 1)

        let activeMutation = try await imageCache.begin(
            id: 0xc002,
            lossy: false,
            mode: .cache,
            retainedByteCount: 3
        )
        let queuedMutation = Task { () -> Result<Void, ChannelError> in
            do {
                let mutation = try await imageCache.begin(
                    id: 0xc002,
                    lossy: false,
                    mode: .cache,
                    retainedByteCount: 5
                )
                await imageCache.abort(mutation)
                return .success(())
            } catch let error as ChannelError {
                return .failure(error)
            } catch {
                return .failure(.invalidState)
            }
        }
        for _ in 0..<1_000 {
            if await imageCache.diagnosticsSnapshot().queuedMutationCount == 1 { break }
            await Task.yield()
        }
        var diagnostics = await imageCache.diagnosticsSnapshot()
        #expect(diagnostics.pendingMutationCount == 2)
        #expect(diagnostics.pendingReservationCount == 1)
        #expect(diagnostics.queuedMutationCount == 1)
        #expect(diagnostics.mutationRetainedBytes == 8)

        await session.disconnect()

        switch await queuedMutation.value {
        case .success:
            Issue.record("queued cache mutation unexpectedly survived Session disconnect")
        case let .failure(error):
            #expect(error == .transport(.connectionClosed))
        }
        #expect(await imageCache.commit(activeMutation) == .discarded)
        diagnostics = await imageCache.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.pendingMutationCount == 0)
        #expect(diagnostics.queuedMutationCount == 0)
        #expect(diagnostics.mutationRetainedBytes == 0)
        #expect(diagnostics.pendingWaiterCount == 0)
        #expect(diagnostics.retainedBytes == 0)
        await #expect(throws: ChannelError.transport(.connectionClosed)) {
            _ = try await imageCache.resolve(id: 0xc001, requirement: .any)
        }
        #expect(!(await main.isConnected))
        #expect(!(await display.isConnected))
    }

    @Test func publishesAgentConnectedStateFromMainInit() async throws {
        let transport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
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

    @Test func agentManagerRetainsItsSessionEventConsumerAcrossReconnect() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        var supportEvents = manager.displayConfigurationSupportEvents.makeAsyncIterator()
        try await manager.start(session: session)

        let connected = SpiceDisplayConfigurationSupport(
            agentConnected: true,
            hasExplicitPeerCapabilities: false,
            supportsMonitorConfiguration: true,
            supportsSparseMonitors: false,
            supportsMonitorPositions: false
        )
        #expect(await supportEvents.next() == connected)

        async let reconnectBoundary: Void = manager.waitForSessionReconnectBoundary()
        await session.disconnect()
        await reconnectBoundary
        #expect(await supportEvents.next() == SpiceDisplayConfigurationSupport(
            agentConnected: false,
            hasExplicitPeerCapabilities: false,
            supportsMonitorConfiguration: false,
            supportsSparseMonitors: false,
            supportsMonitorPositions: false
        ))

        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        #expect(await supportEvents.next() == connected)
        await second.waitForOutboundCount(6)
        #expect((await manager.diagnosticsSnapshot()).capabilityAnnouncementsSent == 2)

        await manager.stop()
        await session.disconnect()
    }

    @Test func reconnectBoundaryWaitsForDisconnectThatHasNotPublishedItsRevision() async throws {
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

        let disconnectGate = AgentMessageProcessingGate()
        let eventGate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setEventProcessingHookForTesting { event in
            if case .disconnected = event { await eventGate.block() }
        }
        try await manager.start(session: session)
        await session.setDisconnectProcessingHookForTesting {
            await disconnectGate.block()
        }

        let disconnect = Task { await session.disconnect() }
        await disconnectGate.waitUntilEntered()
        #expect(await session.currentAgentDisconnectRevision() == 0)

        let boundaryCompleted = Mutex(false)
        let boundary = Task {
            await manager.waitForSessionReconnectBoundary()
            boundaryCompleted.withLock { $0 = true }
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!boundaryCompleted.withLock { $0 })

        await disconnectGate.release()
        await eventGate.waitUntilEntered()
        await disconnect.value
        #expect(await session.currentAgentDisconnectRevision() == 1)
        #expect(!boundaryCompleted.withLock { $0 })

        await eventGate.release()
        await boundary.value
        #expect(boundaryCompleted.withLock { $0 })
        await manager.stop()
    }

    @Test func cancellingReconnectBoundaryRollsBackQuiesce() async throws {
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

        let boundary = Task { await manager.waitForSessionReconnectBoundary() }
        for _ in 0..<100 {
            if await manager.isReconnectBoundaryQuiescingForTesting() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await manager.isReconnectBoundaryQuiescingForTesting())
        boundary.cancel()
        await boundary.value
        #expect(!(await manager.isReconnectBoundaryQuiescingForTesting()))

        try await manager.requestResolution(width: 800, height: 600)
        await manager.stop()
        await session.disconnect()
    }

    @Test func stoppingManagerReleasesBoundaryWaitingOnConnectedSession() async throws {
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

        let boundaryCompleted = Mutex(false)
        let boundary = Task {
            await manager.waitForSessionReconnectBoundary()
            boundaryCompleted.withLock { $0 = true }
        }
        for _ in 0..<100 {
            if await manager.isReconnectBoundaryQuiescingForTesting() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await manager.isReconnectBoundaryQuiescingForTesting())

        await manager.stop()
        await boundary.value
        #expect(boundaryCompleted.withLock { $0 })
        await session.disconnect()
    }

    @Test func reconnectBoundaryDoesNotAttachToLifecycleThatWonActorHop() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 0,
            agentTokens: 0
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let snapshotGate = AgentMessageProcessingGate()
        let connectedEventGate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setReconnectBoundarySnapshotHookForTesting {
            await snapshotGate.block()
        }
        await manager.setEventProcessingHookForTesting { event in
            if case .connected = event { await connectedEventGate.block() }
        }
        try await manager.start(session: session)

        let boundaryCompleted = Mutex(false)
        let boundary = Task {
            await manager.waitForSessionReconnectBoundary()
            boundaryCompleted.withLock { $0 = true }
        }
        await snapshotGate.waitUntilEntered()
        await session.disconnect()
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        await connectedEventGate.waitUntilEntered()

        await snapshotGate.release()
        for _ in 0..<100 {
            if boundaryCompleted.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(boundaryCompleted.withLock { $0 })
        if !boundaryCompleted.withLock({ $0 }) { boundary.cancel() }
        await boundary.value

        await connectedEventGate.release()
        await second.waitForOutboundCount(6)
        try await manager.requestResolution(width: 800, height: 600)
        await manager.stop()
        await session.disconnect()
    }

    @Test func sameLifecycleAgentRestartDoesNotReleaseReconnectBoundary() async throws {
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
        await transport.waitForOutboundCount(6)

        let boundaryCompleted = Mutex(false)
        let boundary = Task {
            await manager.waitForSessionReconnectBoundary()
            boundaryCompleted.withLock { $0 = true }
        }
        for _ in 0..<100 {
            if await manager.isReconnectBoundaryQuiescingForTesting() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await transport.enqueue(encodeMini(id: 108, body: uint32(0)))
        await transport.enqueue(encodeMini(id: 115, body: uint32(8)))
        for _ in 0..<100 {
            if (await manager.diagnosticsSnapshot()).capabilityAnnouncementsSent == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect((await manager.diagnosticsSnapshot()).capabilityAnnouncementsSent == 2)
        #expect(!boundaryCompleted.withLock { $0 })
        #expect(await manager.isReconnectBoundaryQuiescingForTesting())

        await session.disconnect()
        await boundary.value
        #expect(boundaryCompleted.withLock { $0 })
        await manager.stop()
    }

    @Test func cancellingReconnectBoundaryReleasesOperationDrainWaiter() async throws {
        let source = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-cancel-reconnect-drain-\(UUID().uuidString).txt"
        )
        try Data("drain".utf8).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

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
        let operationGate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setFileInspectionHookForTesting { await operationGate.block() }
        try await manager.start(session: session)

        let transfer = Task { try await manager.sendFile(at: source) }
        await operationGate.waitUntilEntered()
        await session.disconnect()
        let boundary = Task { await manager.waitForSessionReconnectBoundary() }
        for _ in 0..<100 {
            if await manager.isReconnectBoundaryWaitingForOperationsForTesting() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await manager.isReconnectBoundaryWaitingForOperationsForTesting())

        boundary.cancel()
        await boundary.value
        #expect(!(await manager.isReconnectBoundaryQuiescingForTesting()))
        #expect(!(await manager.isReconnectBoundaryWaitingForOperationsForTesting()))

        await operationGate.release()
        await #expect(throws: SpiceFileTransferError.agentUnavailable) {
            try await transfer.value
        }
        await manager.stop()
    }

    @Test func reconnectBoundaryQuiescesConnectionWithoutAgentLifecycle() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 0,
            agentTokens: 0
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)

        #expect(await session.currentAgentDisconnectRevision() == 0)
        await session.disconnect()
        await manager.waitForSessionReconnectBoundary()
        #expect(await session.currentAgentDisconnectRevision() == 0)
        await #expect(throws: SpiceDisplayConfigurationError.agentManagerNotRunning) {
            try await manager.requestResolution(width: 800, height: 600)
        }

        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        for _ in 0..<100 {
            if (await manager.diagnosticsSnapshot()).capabilityAnnouncementsSent == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect((await manager.diagnosticsSnapshot()).capabilityAnnouncementsSent == 1)
        try await manager.requestResolution(width: 800, height: 600)

        await manager.stop()
        await session.disconnect()
    }

    @Test func dequeuedAgentMessageCannotSendAcrossConnectionGeneration() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setMessageProcessingHookForTesting { await gate.block() }
        try await manager.start(session: session)
        await first.waitForOutboundCount(6)

        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopIntegration
        ))
        let oldPacket = try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        await first.enqueue(encodeMini(id: 109, body: oldPacket))
        await gate.waitUntilEntered()

        await session.disconnect()
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        await gate.release()

        for _ in 0..<100 {
            if (await manager.diagnosticsSnapshot()).capabilityAnnouncementsSent == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let outbound = await second.outbound
        let agentPackets = try outbound.compactMap { packet -> Data? in
            guard packet.count >= 6, try decodeMiniMessageID(packet) == 107 else {
                return nil
            }
            return try decodeMiniBody(packet)
        }
        var decoder = VDAgentStreamDecoder()
        let messages = try agentPackets.flatMap { try decoder.append(packet: $0) }
        #expect(messages.filter {
            $0.type == VDAgentMessageType.announceCapabilities.rawValue
        }.count == 1)

        await manager.stop()
        await session.disconnect()
    }

    @Test func dequeuedAgentMessageCannotSendAfterRuntimeAgentRestart() async throws {
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
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setMessageProcessingHookForTesting { await gate.block() }
        try await manager.start(session: session)
        await transport.waitForOutboundCount(6)
        let initialGeneration = await session.currentAgentConnectionSnapshot().generation

        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopIntegration
        ))
        let oldPacket = try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        await transport.enqueue(encodeMini(id: 109, body: oldPacket))
        await gate.waitUntilEntered()
        await transport.enqueue(encodeMini(id: 108, body: uint32(0)))
        await transport.enqueue(encodeMini(id: 115, body: uint32(8)))
        let restartedGeneration = initialGeneration &+ 2
        for _ in 0..<100 {
            if await session.currentAgentConnectionSnapshot().generation
                == restartedGeneration { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(
            await session.currentAgentConnectionSnapshot().generation
                == restartedGeneration
        )
        await gate.release()

        for _ in 0..<100 {
            if (await manager.diagnosticsSnapshot()).capabilityAnnouncementsSent == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
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
        #expect(messages.filter {
            $0.type == VDAgentMessageType.announceCapabilities.rawValue
        }.count == 2)

        await manager.stop()
        await session.disconnect()
    }

    @Test func agentManagerCanRestartItsSessionEventConsumer() async throws {
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
        await transport.waitForOutboundCount(6)
        for _ in 0..<10 { await Task.yield() }

        await manager.stop()
        try await manager.start(session: session)

        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        let packet = try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        await transport.enqueue(encodeMini(id: 109, body: packet))
        for _ in 0..<100 {
            if (await manager.diagnosticsSnapshot()).inboundMessages == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect((await manager.diagnosticsSnapshot()).inboundMessages == 1)

        async let reconnectBoundary: Void = manager.waitForSessionReconnectBoundary()
        await session.disconnect()
        await reconnectBoundary
        await manager.stop()
    }

    @Test func reconnectBoundaryWaitsForDequeuedOldConnectedEvent() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setEventProcessingHookForTesting { _ in await gate.block() }
        try await manager.start(session: session)
        await gate.waitUntilEntered()

        await session.disconnect()
        let retry = Task {
            await manager.waitForSessionReconnectBoundary()
            return try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await second.isConnected))

        await gate.release()
        _ = try await retry.value
        #expect(await second.isConnected)

        await manager.stop()
        await session.disconnect()
    }

    @Test func reconnectBoundaryWaitsWhileAgentManagerStartIsSuspended() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setStartProcessingHookForTesting { await gate.block() }
        let start = Task { try await manager.start(session: session) }
        await gate.waitUntilEntered()

        await session.disconnect()
        let retry = Task {
            await manager.waitForSessionReconnectBoundary()
            return try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await second.isConnected))

        await gate.release()
        try await start.value
        _ = try await retry.value
        #expect(await second.isConnected)

        await manager.stop()
        await session.disconnect()
    }

    @Test func reconnectBoundaryWaitsForSuspendedStartWithoutAgentRevision() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 0,
            agentTokens: 0
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setStartProcessingHookForTesting { await gate.block() }
        let start = Task { try await manager.start(session: session) }
        await gate.waitUntilEntered()

        await session.disconnect()
        let retry = Task {
            await manager.waitForSessionReconnectBoundary()
            return try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await second.isConnected))

        await gate.release()
        try await start.value
        _ = try await retry.value
        #expect(await second.isConnected)

        await manager.stop()
        await session.disconnect()
    }

    @Test func agentManagerStopDrainsDequeuedBoundaryBeforeRestart() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setEventProcessingHookForTesting { event in
            if case .disconnected = event { await gate.block() }
        }
        try await manager.start(session: session)

        await session.disconnect()
        await gate.waitUntilEntered()
        let stop = Task { await manager.stop() }
        for _ in 0..<10 { await Task.yield() }
        await #expect(throws: SpiceClipboardError.alreadyRunning) {
            try await manager.start(session: session)
        }

        await gate.release()
        await stop.value
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        try await manager.start(session: session)

        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        let packet = try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        await second.enqueue(encodeMini(id: 109, body: packet))
        for _ in 0..<100 {
            if (await manager.diagnosticsSnapshot()).inboundMessages == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect((await manager.diagnosticsSnapshot()).inboundMessages == 1)

        await manager.stop()
        await session.disconnect()
    }

    @Test func stoppingSuspendedAgentManagerStartLeavesNoZombiePump() async throws {
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
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setStartProcessingHookForTesting { await gate.block() }
        let start = Task { try await manager.start(session: session) }
        await gate.waitUntilEntered()
        let stop = Task { await manager.stop() }
        for _ in 0..<10 { await Task.yield() }
        await #expect(throws: SpiceClipboardError.alreadyRunning) {
            try await manager.start(session: session)
        }

        await gate.release()
        try await start.value
        await stop.value
        try await manager.start(session: session)

        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        let packet = try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        await transport.enqueue(encodeMini(id: 109, body: packet))
        for _ in 0..<100 {
            if (await manager.diagnosticsSnapshot()).inboundMessages == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect((await manager.diagnosticsSnapshot()).inboundMessages == 1)

        await manager.stop()
        await session.disconnect()
    }

    @Test func agentManagerStopDrainsPublicOperationsAndConcurrentStopCallers() async throws {
        let source = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-stop-drain-\(UUID().uuidString).txt"
        )
        try Data("drain".utf8).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

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
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setFileInspectionHookForTesting { await gate.block() }
        try await manager.start(session: session)

        let transfer = Task { try await manager.sendFile(at: source) }
        await gate.waitUntilEntered()
        let firstStop = Task { await manager.stop() }
        for _ in 0..<10 { await Task.yield() }
        await #expect(throws: SpiceClipboardError.alreadyRunning) {
            try await manager.start(session: session)
        }

        let secondStopCompleted = Mutex(false)
        let secondStop = Task {
            await manager.stop()
            secondStopCompleted.withLock { $0 = true }
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!secondStopCompleted.withLock { $0 })

        await gate.release()
        await #expect(throws: SpiceFileTransferError.agentUnavailable) {
            try await transfer.value
        }
        await firstStop.value
        await secondStop.value
        #expect(secondStopCompleted.withLock { $0 })

        try await manager.start(session: session)
        await manager.stop()
        await session.disconnect()
    }

    @Test func reconnectBoundaryQuiescesAndDrainsPublicOperations() async throws {
        let source = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-reconnect-drain-\(UUID().uuidString).txt"
        )
        try Data("boundary".utf8).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setFileInspectionHookForTesting { await gate.block() }
        try await manager.start(session: session)

        let transfer = Task { try await manager.sendFile(at: source) }
        await gate.waitUntilEntered()
        await session.disconnect()
        let retry = Task {
            await manager.waitForSessionReconnectBoundary()
            return try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await second.isConnected))

        await gate.release()
        await #expect(throws: SpiceFileTransferError.agentUnavailable) {
            try await transfer.value
        }
        _ = try await retry.value
        #expect(await second.isConnected)

        await manager.stop()
        await session.disconnect()
    }

    @Test func reconnectBoundaryRevisionIsScopedToManagerRun() async throws {
        let firstSessionTransport = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let firstSession = SpiceSession(
            transportFactory: { _ in firstSessionTransport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await firstSession.connect(
            endpoint: SpiceEndpoint(host: "first.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: firstSession)
        await firstSession.disconnect()
        await manager.waitForSessionReconnectBoundary()
        await manager.stop()

        let secondSource = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let secondTarget = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let secondTransports = TransportPool([secondSource, secondTarget])
        let secondSession = SpiceSession(
            transportFactory: { _ in secondTransports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await secondSession.connect(
            endpoint: SpiceEndpoint(host: "second.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        await manager.setEventProcessingHookForTesting { event in
            if case .disconnected = event { await gate.block() }
        }
        try await manager.start(session: secondSession)

        await secondSession.disconnect()
        await gate.waitUntilEntered()
        let retry = Task {
            await manager.waitForSessionReconnectBoundary()
            return try await secondSession.connect(
                endpoint: SpiceEndpoint(host: "second.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await secondTarget.isConnected))

        await gate.release()
        _ = try await retry.value
        #expect(await secondTarget.isConnected)

        await manager.stop()
        await secondSession.disconnect()
    }

    @Test func reconnectBoundaryWaitsForInFlightOldAgentMessage() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setMessageProcessingHookForTesting { await gate.block() }
        try await manager.start(session: session)

        let capabilities = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        let packet = try #require(VDAgentWireEncoder.fragments(for: capabilities).first)
        await first.enqueue(encodeMini(id: 109, body: packet))
        await gate.waitUntilEntered()

        await session.disconnect()
        let retry = Task {
            await manager.waitForSessionReconnectBoundary()
            return try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await second.isConnected))

        await gate.release()
        _ = try await retry.value
        #expect(await second.isConnected)

        await manager.stop()
        await session.disconnect()
    }

    @Test func disconnectEndsPlaybackLifecycleWithoutTerminatingItsEventStream() async throws {
        let main = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [SpiceChannelID(type: 5, id: 0)]
        ))
        let playback = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([main, playback])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        var events = session.playbackEvents.makeAsyncIterator()
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )

        await session.disconnect()

        #expect(await events.next() == .stopped)
    }

    @Test func switchHostEndsOldPlaybackBeforeCompletingHandoff() async throws {
        let playbackChannel = [SpiceChannelID(type: 5, id: 0)]
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: playbackChannel
        ))
        let sourcePlayback = StreamingSessionTransport(initial: try makeLinkResponses())
        let target = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: playbackChannel
        ))
        let targetPlayback = StreamingSessionTransport(initial: try makeLinkResponses())
        let transports = TransportPool([
            source,
            sourcePlayback,
            target,
            targetPlayback,
        ])
        let sourceCache = DisplayImageCache()
        let targetCache = DisplayImageCache()
        let imageCaches = ImageCachePool([sourceCache, targetCache])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            imageCacheFactory: { imageCaches.take() }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        var sessionEvents = session.events.makeAsyncIterator()
        var playbackEvents = session.playbackEvents.makeAsyncIterator()

        await source.enqueue(encodeMini(
            id: 111,
            body: migrationDestinationBody(host: "target.example")
        ))
        guard case let .migration(.switching(offer)) = await sessionEvents.next() else {
            Issue.record("expected switch-host migration event")
            return
        }

        #expect(await playbackEvents.next() == .stopped)
        #expect(await sessionEvents.next() == .migration(.completed(offer)))
        #expect(!(await source.isConnected))
        #expect(!(await sourcePlayback.isConnected))
        #expect(await target.isConnected)
        #expect(await targetPlayback.isConnected)
        await expectImageCacheClosed(sourceCache, id: 0xd400)
        try await expectImageCacheOpen(targetCache, id: 0xd401)

        await session.disconnect()
        await expectImageCacheClosed(targetCache, id: 0xd402)
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

    @Test func runtimeAgentRestartCannotReviveCompletedFileSend() async throws {
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
        let gate = AgentMessageProcessingGate()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        await manager.setFileMessageCompletionHookForTesting { await gate.block() }
        var supportEvents = manager.displayConfigurationSupportEvents.makeAsyncIterator()
        try await manager.start(session: session)
        _ = await supportEvents.next()
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
        _ = await supportEvents.next()

        let source = FileManager.default.temporaryDirectory.appending(
            path: "spice-swift-agent-restart-\(UUID().uuidString).bin"
        )
        try Data([1, 2, 3]).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        var fileEvents = manager.fileTransferEvents.makeAsyncIterator()
        let transfer = Task { try await manager.sendFile(at: source) }
        let queued = try #require(await fileEvents.next())
        guard case let .queued(id, _, _) = queued else {
            Issue.record("expected queued file transfer")
            return
        }
        await gate.waitUntilEntered()

        await transport.enqueue(encodeMini(id: 108, body: uint32(0)))
        await transport.enqueue(encodeMini(id: 115, body: uint32(8)))
        #expect((await supportEvents.next())?.agentConnected == false)
        #expect(await fileEvents.next() == .failed(id: id, .agentUnavailable))
        #expect((await supportEvents.next())?.agentConnected == true)

        await gate.release()
        await #expect(throws: SpiceFileTransferError.agentUnavailable) {
            try await transfer.value
        }
        #expect(await manager.activeFileTransferCountForTesting() == 0)

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
            inbound: try makeServerTranscript(channels: [
                SpiceChannelID(type: 2, id: 0),
                SpiceChannelID(type: 3, id: 0),
            ]).map(Result.success)
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

    @Test func disconnectCancelsAnInFlightConnectionBeforeItCanAdopt() async throws {
        let blocked = BlockingTransport()
        let replacement = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: []
        ))
        let transports = TransportPool([blocked, replacement])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )

        let connection = Task {
            try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        await blocked.waitUntilFirstWrite()
        let disconnect = Task { await session.disconnect() }

        do {
            _ = try await connection.value
            Issue.record("disconnect allowed the pending connection to adopt")
        } catch let error as SpiceError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("unexpected connection error: \(error)")
        }
        await disconnect.value
        #expect(await blocked.isClosed)
        #expect(await session.currentAgentConnectionSnapshot().sessionLifecycleID == nil)

        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        #expect(await replacement.isConnected)
        await session.disconnect()
    }

    @Test func connectCannotAdoptWhileDisconnectCleanupIsSuspended() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let gate = AgentMessageProcessingGate()
        await session.setDisconnectProcessingHookForTesting { await gate.block() }

        let disconnect = Task { await session.disconnect() }
        await gate.waitUntilEntered()
        await #expect(throws: SpiceError.alreadyConnected) {
            try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        #expect(!(await second.isConnected))

        await gate.release()
        await disconnect.value
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        #expect(await second.isConnected)
        await session.disconnect()
    }

    @Test func failedConnectionResumesExactLifecycleWaiters() async throws {
        let transport = BlockingTransport()
        let session = SpiceSession(
            transportFactory: { _ in transport },
            ticketEncryptor: SessionTicketEncryptor()
        )
        let connection = Task {
            try await session.connect(
                endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
                credentials: SpiceCredentials(password: "secret")
            )
        }
        await transport.waitUntilFirstWrite()
        let lifecycleID = try #require(
            await session.currentAgentConnectionSnapshot().sessionLifecycleID
        )
        let waiterCompleted = Mutex(false)
        let waiter = Task {
            await session.waitUntilConnectionInactiveForReconnect(
                observedLifecycleID: lifecycleID
            )
            waiterCompleted.withLock { $0 = true }
        }

        await transport.close()
        do {
            _ = try await connection.value
            Issue.record("closed transport unexpectedly connected")
        } catch {
            // The exact transport failure is not relevant to the lifecycle fence.
        }
        await waiter.value
        #expect(waiterCompleted.withLock { $0 })
        #expect(await session.currentAgentConnectionSnapshot().sessionLifecycleID == nil)
    }

    @Test func exactLifecycleWaitDoesNotAttachToAReplacementConnection() async throws {
        let first = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let second = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let transports = TransportPool([first, second])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let oldLifecycleID = try #require(
            await session.currentAgentConnectionSnapshot().sessionLifecycleID
        )
        await session.disconnect()
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )

        await session.waitUntilConnectionInactiveForReconnect(
            observedLifecycleID: oldLifecycleID
        )
        #expect(await second.isConnected)
        await session.disconnect()
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
        let sourceCache = DisplayImageCache()
        let targetCache = DisplayImageCache()
        let imageCaches = ImageCachePool([sourceCache, targetCache])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            imageCacheFactory: { imageCaches.take() }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let desktop = session.desktop.subscribe()
        desktop.setDemand(.visible)
        var desktopUpdates = desktop.updates.makeAsyncIterator()
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

        #expect(await events.next() == .migration(.completed(offer)))
        var targetPointerMode: SpicePointerMode?
        for _ in 0..<4 {
            guard let snapshot = await desktopUpdates.next() else { break }
            targetPointerMode = snapshot.pointerMode
            if targetPointerMode == .relative { break }
        }
        #expect(targetPointerMode == .relative)
        // Runtime mouse-mode renegotiation adds a target-side
        // MAIN_MOUSE_MODE_REQUEST before the final MIGRATE_END acknowledgement.
        await target.waitForOutboundCount(5)
        let targetOutbound = await target.outbound
        #expect(try targetOutbound.suffix(2).map(decodeMiniMessageID) == [109, 105])
        #expect(!(await source.isConnected))
        #expect(await target.isConnected)
        #expect(!(await sourceInputs.isConnected))
        #expect(await targetInputs.isConnected)
        try await expectImageCacheOpen(sourceCache, id: 0xd100)
        await expectImageCacheClosed(targetCache, id: 0xd101)
        desktop.cancel()
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
        await expectImageCacheClosed(sourceCache, id: 0xd102)
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
        let sourceCache = DisplayImageCache()
        let preparedTargetCache = DisplayImageCache()
        let imageCaches = ImageCachePool([sourceCache, preparedTargetCache])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            imageCacheFactory: { imageCaches.take() }
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
        try await expectImageCacheOpen(sourceCache, id: 0xd200)
        await expectImageCacheClosed(preparedTargetCache, id: 0xd201)

        let targetInputCount = await targetInputs.outbound.count
        try await session.send(.mousePosition(x: 40, y: 50, displayID: 0))
        await targetInputs.waitForOutboundCount(targetInputCount + 1)
        let reboundInput = try #require((await targetInputs.outbound).last)
        #expect(try decodeMiniMessageID(reboundInput) == 112)
        var reboundBody = try ByteReader(try decodeMiniBody(reboundInput), offset: 8)
        #expect(try reboundBody.readUInt16LE() == 1)
        await session.disconnect()
        await expectImageCacheClosed(sourceCache, id: 0xd202)
    }

    @Test func agentManagerRemainsUsableAfterSeamlessMigration() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 8
        ))
        let target = StreamingSessionTransport(
            initial: try makeLinkResponses(mainCapabilities: [0x8])
                + [encodeMini(id: 117, body: Data())]
        )
        let transports = TransportPool([source, target])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)
        try await manager.start(session: session)
        await source.waitForOutboundCount(6)
        var events = session.events.makeAsyncIterator()

        await source.enqueue(encodeMini(
            id: 116,
            body: migrationDestinationBody(host: "target.example") + uint32(9)
        ))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: true)))
        for _ in 0..<100 {
            if try (await source.outbound).contains(where: {
                try decodeMiniMessageID($0) == 111
            }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        await source.enqueue(encodeMini(id: 1, body: uint32(3)))
        await source.enqueue(encodeMini(id: 2, body: Data("main-state".utf8)))
        #expect(await events.next() == .migration(.committing(offer)))
        #expect(await events.next() == .migration(.completed(offer)))

        try await manager.requestResolution(width: 1_280, height: 720)
        for _ in 0..<100 {
            if try (await target.outbound).contains(where: {
                try decodeMiniMessageID($0) == 107
            }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let agentPackets = try (await target.outbound).compactMap { packet -> Data? in
            guard try decodeMiniMessageID(packet) == 107 else { return nil }
            return try decodeMiniBody(packet)
        }
        var decoder = VDAgentStreamDecoder()
        let messages = try agentPackets.flatMap { try decoder.append(packet: $0) }
        #expect(messages.contains(where: {
            $0.type == VDAgentMessageType.monitorsConfig.rawValue
        }))

        await manager.stop()
        await session.disconnect()
    }

    @Test func seamlessMigrationDrainsInFlightAgentMessageBeforeClosingSource() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 16
        ))
        let target = StreamingSessionTransport(
            initial: try makeLinkResponses(mainCapabilities: [0x8])
                + [encodeMini(id: 117, body: Data())]
        )
        let transports = TransportPool([source, target])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let desktop = session.desktop.subscribe()
        desktop.setDemand(.visible)
        var desktopUpdates = desktop.updates.makeAsyncIterator()
        var events = session.events.makeAsyncIterator()
        let sourceAgentMessage = SpiceAgentMessage(
            protocolID: VDAgentMessage.protocolVersion,
            type: VDAgentMessageType.clipboard.rawValue,
            opaque: 0x55,
            data: Data(repeating: 0xa5, count: 6_000)
        )
        let expectedSourceFragments = try VDAgentWireEncoder.fragments(for: VDAgentMessage(
            protocolID: sourceAgentMessage.protocolID,
            type: sourceAgentMessage.type,
            opaque: sourceAgentMessage.opaque,
            data: sourceAgentMessage.data
        ))
        #expect(expectedSourceFragments.count > 1)

        await source.blockNextWrite()
        let sourceSend = Task {
            try await session.sendAgentMessage(sourceAgentMessage)
        }
        await source.waitUntilWriteIsBlocked()

        await source.enqueue(encodeMini(
            id: 116,
            body: migrationDestinationBody(host: "target.example") + uint32(9)
        ))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: true)))
        await source.enqueue(encodeMini(id: 1, body: uint32(3)))
        await source.enqueue(encodeMini(id: 2, body: Data("main-state".utf8)))
        #expect(await events.next() == .migration(.committing(offer)))

        // Target supervision starts after the connections are atomically
        // rebound, but before adoption is allowed to close the retired Main.
        // Observing this runtime update therefore proves adoption has reached
        // its old-Main retirement fence.
        await target.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 1)
        ))
        var targetPointerMode: SpicePointerMode?
        for _ in 0..<4 {
            guard let snapshot = await desktopUpdates.next() else { break }
            targetPointerMode = snapshot.pointerMode
            if targetPointerMode == .relative { break }
        }
        #expect(targetPointerMode == .relative)
        #expect(await source.isConnected)

        await source.releaseBlockedWrite()
        try await sourceSend.value
        #expect(await events.next() == .migration(.completed(offer)))
        await source.waitUntilClosed()

        let sourceOutbound = await source.outbound
        let sourceAgentIndices = try sourceOutbound.indices.filter {
            try decodeMiniMessageID(sourceOutbound[$0]) == 107
        }
        #expect(sourceAgentIndices.count == expectedSourceFragments.count)
        if let first = sourceAgentIndices.first, let last = sourceAgentIndices.last {
            #expect(sourceAgentIndices == Array(first...last))
        }
        let sourceFragments = try sourceAgentIndices.map {
            try decodeMiniBody(sourceOutbound[$0])
        }
        #expect(sourceFragments == expectedSourceFragments)
        #expect(!(await source.isConnected))
        #expect(await target.isConnected)

        let targetAgentMessage = SpiceAgentMessage(
            protocolID: VDAgentMessage.protocolVersion,
            type: VDAgentMessageType.monitorsConfig.rawValue,
            opaque: 0x77,
            data: Data("target-agent".utf8)
        )
        let targetCount = await target.outbound.count
        try await session.sendAgentMessage(targetAgentMessage)
        await target.waitForOutboundCount(targetCount + 1)
        let targetPacket = try #require((await target.outbound).last)
        #expect(try decodeMiniMessageID(targetPacket) == 107)
        var decoder = VDAgentStreamDecoder()
        let decoded = try decoder.append(packet: decodeMiniBody(targetPacket))
        #expect(decoded == [VDAgentMessage(
            protocolID: targetAgentMessage.protocolID,
            type: targetAgentMessage.type,
            opaque: targetAgentMessage.opaque,
            data: targetAgentMessage.data
        )])

        desktop.cancel()
        await session.disconnect()
    }

    @Test func disconnectCancelsSeamlessAdoptionWaitingForRetiredAgentSend() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(
            channels: [],
            agentConnected: 1,
            agentTokens: 16
        ))
        let target = StreamingSessionTransport(
            initial: try makeLinkResponses(mainCapabilities: [0x8])
                + [encodeMini(id: 117, body: Data())]
        )
        let transports = TransportPool([source, target])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor()
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let desktop = session.desktop.subscribe()
        desktop.setDemand(.visible)
        var desktopUpdates = desktop.updates.makeAsyncIterator()
        var events = session.events.makeAsyncIterator()
        let sourceAgentMessage = SpiceAgentMessage(
            protocolID: VDAgentMessage.protocolVersion,
            type: VDAgentMessageType.clipboard.rawValue,
            opaque: 0x99,
            data: Data(repeating: 0x5a, count: 6_000)
        )

        await source.blockNextWrite()
        let sourceSend = Task {
            try await session.sendAgentMessage(sourceAgentMessage)
        }
        await source.waitUntilWriteIsBlocked()

        await source.enqueue(encodeMini(
            id: 116,
            body: migrationDestinationBody(host: "target.example") + uint32(9)
        ))
        let offer = try #require(preparingOffer(await events.next()))
        #expect(await events.next() == .migration(.ready(offer, seamless: true)))
        await source.enqueue(encodeMini(id: 1, body: uint32(3)))
        await source.enqueue(encodeMini(id: 2, body: Data("main-state".utf8)))
        #expect(await events.next() == .migration(.committing(offer)))

        await target.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 1)
        ))
        var targetPointerMode: SpicePointerMode?
        for _ in 0..<4 {
            guard let snapshot = await desktopUpdates.next() else { break }
            targetPointerMode = snapshot.pointerMode
            if targetPointerMode == .relative { break }
        }
        #expect(targetPointerMode == .relative)
        #expect(await source.isConnected)
        #expect(await target.isConnected)

        let disconnectFinished = Mutex(false)
        let disconnectTask = Task {
            await session.disconnect()
            disconnectFinished.withLock { $0 = true }
        }
        for _ in 0..<100 {
            if disconnectFinished.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let completedWithoutManualGateRelease = disconnectFinished.withLock { $0 }
        #expect(completedWithoutManualGateRelease)
        var manuallyReleasedGate = false
        if !completedWithoutManualGateRelease {
            // Keep failure-first runs finite: old adoption leaves the retired
            // continuation unreachable, so release it only after recording
            // the timeout that distinguishes the bug.
            await source.releaseBlockedWrite()
            manuallyReleasedGate = true
        }
        await disconnectTask.value

        for _ in 0..<100 where await source.isConnected {
            try await Task.sleep(for: .milliseconds(1))
        }
        let sourceClosedWithoutManualGateRelease = !(await source.isConnected)
        #expect(sourceClosedWithoutManualGateRelease)
        if !sourceClosedWithoutManualGateRelease && !manuallyReleasedGate {
            // A second old failure mode lets disconnect return after losing
            // ownership of the retired Main. Unblock its caller so this
            // failure-first regression can still finish deterministically.
            await source.releaseBlockedWrite()
            manuallyReleasedGate = true
        }
        await #expect(throws: SpiceError.connectionFailed("connectionClosed")) {
            try await sourceSend.value
        }
        if await source.isConnected {
            await source.close()
        }
        #expect(!(await source.isConnected))
        #expect(!(await target.isConnected))
        #expect(!(await session.currentAgentConnectionState()))
        desktop.cancel()
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
        let sourceCache = DisplayImageCache()
        let targetCache = DisplayImageCache()
        let imageCaches = ImageCachePool([sourceCache, targetCache])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            imageCacheFactory: { imageCaches.take() }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let desktop = session.desktop.subscribe()
        desktop.setDemand(.visible)
        var desktopUpdates = desktop.updates.makeAsyncIterator()
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
        await expectImageCacheClosed(targetCache, id: 0xd500)
        try await expectImageCacheOpen(sourceCache, id: 0xd501)

        await source.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 2)
        ))
        #expect(try #require(await desktopUpdates.next()).pointerMode == .absolute)
        #expect(await session.currentAgentConnectionState() == false)
        desktop.cancel()
        await session.disconnect()
        await expectImageCacheClosed(sourceCache, id: 0xd502)
    }

    @Test func cancellingMigrationPreparationClosesOnlyTargetTransport() async throws {
        let source = StreamingSessionTransport(initial: try makeServerTranscript(channels: []))
        let target = BlockingTransport()
        let transports = TransportPool([source, target])
        let sourceCache = DisplayImageCache()
        let targetCache = DisplayImageCache()
        let imageCaches = ImageCachePool([sourceCache, targetCache])
        let session = SpiceSession(
            transportFactory: { _ in transports.take() },
            ticketEncryptor: SessionTicketEncryptor(),
            imageCacheFactory: { imageCaches.take() }
        )
        _ = try await session.connect(
            endpoint: SpiceEndpoint(host: "fixture.invalid", port: 5_900),
            credentials: SpiceCredentials(password: "secret")
        )
        let desktop = session.desktop.subscribe()
        desktop.setDemand(.visible)
        var desktopUpdates = desktop.updates.makeAsyncIterator()
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
        await expectImageCacheClosed(targetCache, id: 0xd300)
        try await expectImageCacheOpen(sourceCache, id: 0xd301)

        await source.enqueue(try encodeMini(
            SpiceMsgMainMouseMode(supportedModes: 1, currentMode: 1)
        ))
        var resumedPointerMode: SpicePointerMode?
        for _ in 0..<4 {
            guard let snapshot = await desktopUpdates.next() else { break }
            resumedPointerMode = snapshot.pointerMode
            if resumedPointerMode == .relative { break }
        }
        #expect(resumedPointerMode == .relative)
        desktop.cancel()
        await session.disconnect()
        await expectImageCacheClosed(sourceCache, id: 0xd302)
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

    private func displayChannelIDs(count: Int) -> [SpiceChannelID] {
        (0..<count).map { SpiceChannelID(type: 2, id: UInt8($0)) }
    }

    private func gatedChildTransports(
        count: Int,
        probe: BoundedChildConnectProbe,
        ignoresCancellationIDs: Set<Int> = []
    ) throws -> [GatedChildTransport] {
        try (0..<count).map { id in
            GatedChildTransport(
                id: id,
                probe: probe,
                inbound: try makeLinkResponses(),
                ignoresTaskCancellation: ignoresCancellationIDs.contains(id)
            )
        }
    }

    private func streamingChildTransports(
        count: Int
    ) throws -> [StreamingSessionTransport] {
        try (0..<count).map { _ in
            StreamingSessionTransport(initial: try makeLinkResponses())
        }
    }

    private func transportFactory(
        main: any SpiceTransport,
        children: [GatedChildTransport]
    ) -> @Sendable (SpiceEndpoint) -> any SpiceTransport {
        var transports: [any SpiceTransport] = [main]
        transports.append(contentsOf: children)
        return transportFactory(transports)
    }

    private func transportFactory(
        _ transports: [any SpiceTransport]
    ) -> @Sendable (SpiceEndpoint) -> any SpiceTransport {
        let pool = TransportPool(transports)
        return { _ in pool.take() }
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

    private func sessionCachedCopyBody(descriptorID: UInt64) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(1)
        for value: Int32 in [0, 0, 1, 2] {
            writer.writeInt32LE(value)
        }
        writer.writeUInt8(0)
        let imageOffset = UInt32(writer.data.count + 36)
        writer.writeUInt32LE(imageOffset)
        for value: Int32 in [0, 0, 1, 2] {
            writer.writeInt32LE(value)
        }
        writer.writeUInt16LE(0x08)
        writer.writeUInt8(0)
        writer.writeUInt8(0)
        writer.writeInt32LE(0)
        writer.writeInt32LE(0)
        writer.writeUInt32LE(0)
        writer.writeUInt64LE(descriptorID)
        writer.writeUInt8(103)
        writer.writeUInt8(0)
        writer.writeUInt32LE(2)
        writer.writeUInt32LE(1)
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

private func expectImageCacheOpen(
    _ cache: DisplayImageCache,
    id: UInt64
) async throws {
    let bitmap = RawBitmap(
        format: .xRGB8888,
        width: 1,
        height: 1,
        stride: 4,
        topDown: true,
        pixels: Data([1, 2, 3, 0])
    )
    let reservation = try await cache.reserve(
        id: id,
        bitmap: bitmap,
        lossy: false,
        mode: .cache
    )
    #expect(await cache.commit(reservation) == .committed)
    #expect(try await cache.resolve(id: id, requirement: .any) == bitmap)
}

private func expectImageCacheClosed(
    _ cache: DisplayImageCache,
    id: UInt64
) async {
    await #expect(throws: ChannelError.transport(.connectionClosed)) {
        _ = try await cache.reserve(
            id: id,
            bitmap: RawBitmap(
                format: .xRGB8888,
                width: 1,
                height: 1,
                stride: 4,
                topDown: true,
                pixels: Data([1, 2, 3, 0])
            ),
            lossy: false,
            mode: .cache
        )
    }
    await #expect(throws: ChannelError.transport(.connectionClosed)) {
        _ = try await cache.resolve(id: id, requirement: .any)
    }
}

private final class ImageCachePool: Sendable {
    private let caches: Mutex<[DisplayImageCache]>

    init(_ caches: [DisplayImageCache]) {
        self.caches = Mutex(caches)
    }

    func take() -> DisplayImageCache {
        caches.withLock { caches in
            caches.removeFirst()
        }
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

private actor BoundedChildConnectProbe {
    private typealias Outcome = Result<Void, TransportError>

    private var activeIDs: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Outcome, Never>] = [:]
    private var earlyOutcomes: [Int: Outcome] = [:]
    private var ignoresCancellation: Set<Int> = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var activeCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var startedIDs: [Int] = []
    private(set) var peakActiveCount = 0

    var activeCount: Int { activeIDs.count }

    func connect(id: Int, ignoresTaskCancellation: Bool) async throws(TransportError) {
        if ignoresTaskCancellation {
            ignoresCancellation.insert(id)
        }
        activeIDs.insert(id)
        startedIDs.append(id)
        peakActiveCount = max(peakActiveCount, activeIDs.count)
        let ready = startWaiters.filter { startedIDs.count >= $0.0 }
        startWaiters.removeAll { startedIDs.count >= $0.0 }
        for (_, waiter) in ready {
            waiter.resume()
        }
        resumeActiveCountWaiters()

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let early = earlyOutcomes.removeValue(forKey: id) {
                    continuation.resume(returning: early)
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        try outcome.get()
    }

    func waitUntilStarted(count: Int) async {
        guard startedIDs.count < count else {
            return
        }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func waitUntilActiveCount(_ count: Int) async {
        guard activeIDs.count != count else {
            return
        }
        await withCheckedContinuation { activeCountWaiters.append((count, $0)) }
    }

    func succeed(id: Int) {
        finish(id: id, outcome: .success(()))
    }

    func fail(id: Int, reason: String = "injected child connect failure") {
        finish(id: id, outcome: .failure(.connectionFailed(reason)))
    }

    func transportClosed(id: Int) {
        finish(id: id, outcome: .failure(.connectionClosed))
    }

    private func cancel(id: Int) {
        guard !ignoresCancellation.contains(id) else {
            return
        }
        finish(id: id, outcome: .failure(.cancelled))
    }

    private func finish(id: Int, outcome: Outcome) {
        guard activeIDs.remove(id) != nil else {
            return
        }
        resumeActiveCountWaiters()
        ignoresCancellation.remove(id)
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(returning: outcome)
        } else {
            earlyOutcomes[id] = outcome
        }
    }

    private func resumeActiveCountWaiters() {
        let ready = activeCountWaiters.filter { activeIDs.count == $0.0 }
        activeCountWaiters.removeAll { activeIDs.count == $0.0 }
        for (_, waiter) in ready {
            waiter.resume()
        }
    }
}

private actor GatedChildTransport: SpiceTransport {
    private let id: Int
    private let probe: BoundedChildConnectProbe
    private let ignoresTaskCancellation: Bool
    private let inbound: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private(set) var outbound: [Data] = []
    private(set) var connectCallCount = 0
    private(set) var isConnected = false
    private(set) var isClosed = false
    private var closedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        id: Int,
        probe: BoundedChildConnectProbe,
        inbound: [Data],
        ignoresTaskCancellation: Bool = false
    ) {
        self.id = id
        self.probe = probe
        self.ignoresTaskCancellation = ignoresTaskCancellation
        let pipe = AsyncStream.makeStream(of: Data.self)
        self.inbound = pipe.stream
        inboundContinuation = pipe.continuation
        for packet in inbound {
            pipe.continuation.yield(packet)
        }
    }

    func connect() async throws(TransportError) {
        connectCallCount += 1
        try await probe.connect(
            id: id,
            ignoresTaskCancellation: ignoresTaskCancellation
        )
        guard !isClosed else {
            throw .connectionClosed
        }
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard isConnected, !isClosed else {
            throw .connectionClosed
        }
        for await packet in inbound {
            guard packet.count >= minimum, packet.count <= maximum else {
                throw .connectionFailed("gated fixture returned an invalid read size")
            }
            return packet
        }
        throw Task.isCancelled ? .cancelled : .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected, !isClosed else {
            throw .connectionClosed
        }
        outbound.append(data)
    }

    func waitUntilClosed() async {
        guard !isClosed, isConnected || connectCallCount > 0 else {
            return
        }
        await withCheckedContinuation { closedWaiters.append($0) }
    }

    func close() async {
        isClosed = true
        isConnected = false
        inboundContinuation.finish()
        for waiter in closedWaiters {
            waiter.resume()
        }
        closedWaiters.removeAll()
        await probe.transportClosed(id: id)
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
    private var shouldBlockNextWrite = false
    private var writeIsBlocked = false
    private var blockedWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedWriteRelease: CheckedContinuation<Void, Never>?
    private var closedWaiters: [CheckedContinuation<Void, Never>] = []

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
        if shouldBlockNextWrite {
            shouldBlockNextWrite = false
            writeIsBlocked = true
            let waiters = blockedWriteWaiters
            blockedWriteWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                blockedWriteRelease = continuation
            }
            writeIsBlocked = false
            guard isConnected else {
                throw .connectionClosed
            }
        }
        outbound.append(data)
        writeContinuation.yield(())
    }

    func blockNextWrite() {
        shouldBlockNextWrite = true
    }

    func waitUntilWriteIsBlocked() async {
        guard !writeIsBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWriteWaiters.append(continuation)
        }
    }

    func releaseBlockedWrite() {
        blockedWriteRelease?.resume()
        blockedWriteRelease = nil
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

    func waitUntilClosed() async {
        guard isConnected else {
            return
        }
        await withCheckedContinuation { closedWaiters.append($0) }
    }

    func close() async {
        isConnected = false
        shouldBlockNextWrite = false
        blockedWriteRelease?.resume()
        blockedWriteRelease = nil
        for waiter in closedWaiters {
            waiter.resume()
        }
        closedWaiters.removeAll()
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

private actor AgentMessageProcessingGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
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
