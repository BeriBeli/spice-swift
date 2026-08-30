import Foundation
import SpiceCodecs
import SpiceTestSupport
import SpiceTransport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceMetalCompositor
@testable import SpiceProtocol
@testable import SpiceRenderer
@testable import SpiceWire

@Suite("Display Channel wire execution")
struct DisplayChannelTests {
    @Test func runKeepsOnlyLatestMJPEGWhileDecodeIsBusy() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 1,
                data: Data([1])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 2,
                data: Data([2])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 3,
                data: Data([3])
            )),
        ]
        let transport = GatedDisplayTransport(inbound: inbound, gateAfterReads: 3)
        try await transport.connect()
        let decoder = GatedPatternJPEGDecoder()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            framePublicationInterval: .zero
        )
        let events = AsyncStream.makeStream(
            of: SpiceChannelEvent.self,
            bufferingPolicy: .unbounded
        )
        let runTask = Task {
            defer { events.continuation.finish() }
            try await channel.run { event in
                _ = events.continuation.yield(event)
            }
        }

        await decoder.waitUntilFirstDecodeStarts()
        await transport.releaseRemainingReads()
        await transport.waitUntilReadCount(5)
        await decoder.releaseFirstDecode()
        await decoder.waitUntilDecodeCount(2)

        var eventIterator = events.stream.makeAsyncIterator()
        var finalFrame: FrameSnapshot?
        while let event = await eventIterator.next() {
            guard case let .frame(frame) = event,
                  frame.snapshot.pixels.first == 90 else { continue }
            finalFrame = frame.snapshot
            break
        }

        #expect(await decoder.payloads == [Data([1]), Data([3])])
        #expect(await channel.diagnosticsSnapshot().mjpeg.supersededBeforeDecode == 1)
        #expect(finalFrame?.revision == 2)
        runTask.cancel()
        _ = try? await runTask.value
        await channel.close()
    }

    @Test func obsoleteRunCleanupKeepsMigratedMJPEGSchedulingActive() async throws {
        let oldTransport = RetirableDisplayTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
        ])
        try await oldTransport.connect()
        let decoder = GatedPatternJPEGDecoder()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: oldTransport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            framePublicationInterval: .zero
        )
        let oldRun = Task { try await channel.run { _ in } }
        await oldTransport.waitUntilReadIsBlocked()
        oldRun.cancel()

        let targetTransport = GatedDisplayTransport(inbound: try [
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 1,
                data: Data([1])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 2,
                data: Data([2])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 3,
                data: Data([3])
            )),
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 2,
                width: 1,
                height: 1,
                format: 32,
                flags: 1
            )),
        ], gateAfterReads: 2)
        try await targetTransport.connect()
        _ = try await channel.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: targetTransport,
            headerMode: .mini
        ))
        let targetRun = Task { try await channel.run { _ in } }
        await targetTransport.waitUntilReadCount(2)
        await decoder.waitUntilFirstDecodeStarts()

        await oldTransport.releaseBlockedRead()
        _ = try? await oldRun.value
        await targetTransport.releaseRemainingReads()

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await targetTransport.readCountSnapshot() < 5,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let schedulingStayedAsynchronous = await targetTransport.readCountSnapshot() == 5
        await decoder.releaseFirstDecode()
        await decoder.waitUntilDecodeCount(2)

        #expect(schedulingStayedAsynchronous)
        let decodedPayloads = await decoder.payloads
        #expect(
            decodedPayloads == [Data([1]), Data([3])],
            "decoded payloads: \(decodedPayloads.map(Array.init))"
        )
        targetRun.cancel()
        _ = try? await targetRun.value
        await channel.close()
    }

    @Test func retiredRunDecodeFailureDoesNotCloseMigrationTarget() async throws {
        let oldTransport = RetirableDisplayTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1, width: 2, height: 2, format: 32, flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 1,
                data: Data([1])
            )),
        ])
        try await oldTransport.connect()
        let decoder = ReleaseFailingJPEGDecoder()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: oldTransport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            framePublicationInterval: .zero
        )
        let oldRun = Task { try await channel.run { _ in } }
        await decoder.waitUntilDecodeStarts()
        await oldTransport.waitUntilReadIsBlocked()
        oldRun.cancel()

        let targetTransport = GatedDisplayTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 2, width: 1, height: 1, format: 32, flags: 1
            )),
        ], gateAfterReads: 0)
        try await targetTransport.connect()
        _ = try await channel.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: targetTransport,
            headerMode: .mini
        ))
        let events = AsyncStream.makeStream(
            of: SpiceChannelEvent.self,
            bufferingPolicy: .unbounded
        )
        let targetRun = Task {
            defer { events.continuation.finish() }
            try await channel.run { event in
                _ = events.continuation.yield(event)
            }
        }
        await targetTransport.waitUntilGateIsBlocking()

        await oldTransport.releaseBlockedRead()
        _ = try? await oldRun.value
        await decoder.releaseWithFailure()
        try await Task.sleep(for: .milliseconds(10))
        await targetTransport.releaseRemainingReads()

        var eventIterator = events.stream.makeAsyncIterator()
        var targetStayedConnected = false
        while let event = await eventIterator.next() {
            guard event == .surfaceCreated(2) else { continue }
            targetStayedConnected = true
            break
        }
        #expect(targetStayedConnected)
        targetRun.cancel()
        _ = try? await targetRun.value
        await channel.close()
    }

    @Test func staleMJPEGDecodeCannotOverwriteLaterDrawCommand() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 4,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 4,
                streamHeight: 2,
                sourceWidth: 4,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 4),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 1,
                data: Data([1])
            )),
            encodeMini(id: 302, body: drawFillBody()),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 2,
                data: Data([2])
            )),
        ]
        let transport = GatedDisplayTransport(inbound: inbound, gateAfterReads: 3)
        try await transport.connect()
        let decoder = GatedPatternJPEGDecoder()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            framePublicationInterval: .zero
        )
        let events = AsyncStream.makeStream(
            of: SpiceChannelEvent.self,
            bufferingPolicy: .unbounded
        )
        let runTask = Task {
            defer { events.continuation.finish() }
            try await channel.run { event in
                _ = events.continuation.yield(event)
            }
        }

        await decoder.waitUntilFirstDecodeStarts()
        await transport.releaseRemainingReads()
        await transport.waitUntilReadCount(5)

        var eventIterator = events.stream.makeAsyncIterator()
        while let event = await eventIterator.next() {
            guard case let .frame(frame) = event,
                  pixel(frame.snapshot, x: 0, y: 0) == [0, 0, 255, 255]
            else {
                continue
            }
            break
        }

        await decoder.releaseFirstDecode()
        var finalFrame: FrameSnapshot?
        while let event = await eventIterator.next() {
            guard case let .frame(frame) = event,
                  frame.snapshot.pixels.first == 50 else { continue }
            finalFrame = frame.snapshot
            break
        }

        #expect(await decoder.payloads == [Data([1]), Data([2])])
        #expect(finalFrame?.revision == 2)
        #expect(finalFrame.map { pixel($0, x: 0, y: 0) } == [50, 0, 0, 255])
        runTask.cancel()
        _ = try? await runTask.value
        await channel.close()
    }

    @Test func streamDestroyCancellationDoesNotCloseDisplayChannel() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 1,
                data: Data([1])
            )),
            encodeMini(id: 125, body: streamDestroyBody(streamID: 7)),
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 2,
                width: 1,
                height: 1,
                format: 32,
                flags: 1
            )),
        ]
        let transport = GatedDisplayTransport(inbound: inbound, gateAfterReads: 3)
        try await transport.connect()
        let decoder = CancellationAwareJPEGDecoder()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            framePublicationInterval: .zero
        )
        let events = AsyncStream.makeStream(
            of: SpiceChannelEvent.self,
            bufferingPolicy: .unbounded
        )
        let runTask = Task {
            defer { events.continuation.finish() }
            try await channel.run { event in
                _ = events.continuation.yield(event)
            }
        }

        await decoder.waitUntilDecodeStarts()
        await transport.releaseRemainingReads()

        var eventIterator = events.stream.makeAsyncIterator()
        var sawSentinelSurface = false
        while let event = await eventIterator.next() {
            guard event == .surfaceCreated(2) else { continue }
            sawSentinelSurface = true
            break
        }

        #expect(sawSentinelSurface)
        await decoder.waitUntilCancelled()
        #expect(await decoder.wasCancelled)
        runTask.cancel()
        _ = try? await runTask.value
        await channel.close()
    }

    @Test func surfaceDestroyCancelsInFlightMJPEGBeforeContinuing() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1, width: 2, height: 2, format: 32, flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7, multimediaTime: 1, data: Data([1])
            )),
            encodeMini(SpiceMsgDisplaySurfaceDestroy(surfaceID: 1)),
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 2, width: 1, height: 1, format: 32, flags: 1
            )),
        ]
        let transport = GatedDisplayTransport(inbound: inbound, gateAfterReads: 3)
        try await transport.connect()
        let decoder = CancellationAwareJPEGDecoder()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            framePublicationInterval: .zero
        )
        let events = AsyncStream.makeStream(
            of: SpiceChannelEvent.self,
            bufferingPolicy: .unbounded
        )
        let runTask = Task {
            defer { events.continuation.finish() }
            try await channel.run { event in
                _ = events.continuation.yield(event)
            }
        }

        await decoder.waitUntilDecodeStarts()
        await transport.releaseRemainingReads()
        var eventIterator = events.stream.makeAsyncIterator()
        var sawSentinelSurface = false
        while let event = await eventIterator.next() {
            guard event == .surfaceCreated(2) else { continue }
            sawSentinelSurface = true
            break
        }

        #expect(sawSentinelSurface)
        await decoder.waitUntilCancelled()
        #expect(await decoder.wasCancelled)
        runTask.cancel()
        _ = try? await runTask.value
        await channel.close()
    }

    @Test func surfaceVideoSequenceRejectsLateFrameFromAnotherStream() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1, width: 4, height: 2, format: 32, flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 4,
                streamHeight: 2,
                sourceWidth: 4,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 4),
                clipRectangles: nil
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 8,
                streamWidth: 4,
                streamHeight: 2,
                sourceWidth: 4,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 4),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7, multimediaTime: 1, data: Data([1])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 8, multimediaTime: 2, data: Data([2])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7, multimediaTime: 3, data: Data([3])
            )),
        ]
        let transport = GatedDisplayTransport(inbound: inbound, gateAfterReads: 4)
        try await transport.connect()
        let decoder = GatedPatternJPEGDecoder()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            framePublicationInterval: .zero
        )
        let events = AsyncStream.makeStream(
            of: SpiceChannelEvent.self,
            bufferingPolicy: .unbounded
        )
        let runTask = Task {
            defer { events.continuation.finish() }
            try await channel.run { event in
                _ = events.continuation.yield(event)
            }
        }

        await decoder.waitUntilFirstDecodeStarts()
        await transport.releaseRemainingReads()
        await transport.waitUntilReadCount(6)

        var eventIterator = events.stream.makeAsyncIterator()
        while let event = await eventIterator.next() {
            guard case let .frame(frame) = event,
                  frame.snapshot.pixels.first == 50 else { continue }
            #expect(frame.snapshot.revision == 1)
            break
        }

        await decoder.releaseFirstDecode()
        var finalFrame: FrameSnapshot?
        while let event = await eventIterator.next() {
            guard case let .frame(frame) = event,
                  frame.snapshot.pixels.first == 90 else { continue }
            finalFrame = frame.snapshot
            break
        }

        #expect(await decoder.payloads == [Data([1]), Data([2]), Data([3])])
        #expect(finalFrame?.revision == 2)
        runTask.cancel()
        _ = try? await runTask.value
        await channel.close()
    }

    @Test func queuedMJPEGFrameKeepsClipFromItsDataMessage() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1, width: 4, height: 2, format: 32, flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 4,
                streamHeight: 2,
                sourceWidth: 4,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 4),
                clipRectangles: [(top: 0, left: 0, bottom: 2, right: 2)]
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7, multimediaTime: 1, data: Data([1])
            )),
            encodeMini(id: 124, body: streamClipBody(
                streamID: 7,
                rectangles: [(top: 0, left: 2, bottom: 2, right: 4)]
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7, multimediaTime: 2, data: Data([2])
            )),
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 2, width: 1, height: 1, format: 32, flags: 1
            )),
        ]
        let transport = GatedDisplayTransport(inbound: inbound, gateAfterReads: 3)
        try await transport.connect()
        let decoder = GatedPatternJPEGDecoder()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            framePublicationInterval: .zero
        )
        let events = AsyncStream.makeStream(
            of: SpiceChannelEvent.self,
            bufferingPolicy: .unbounded
        )
        let runTask = Task {
            defer { events.continuation.finish() }
            try await channel.run { event in
                _ = events.continuation.yield(event)
            }
        }

        await decoder.waitUntilFirstDecodeStarts()
        await transport.releaseRemainingReads()
        var eventIterator = events.stream.makeAsyncIterator()
        while let event = await eventIterator.next() {
            guard event == .surfaceCreated(2) else { continue }
            break
        }
        await decoder.releaseFirstDecode()

        var finalFrame: FrameSnapshot?
        while let event = await eventIterator.next() {
            guard case let .frame(frame) = event,
                  frame.snapshot.pixels.first == 10 else { continue }
            if pixel(frame.snapshot, x: 2, y: 0) == [70, 0, 0, 255] {
                finalFrame = frame.snapshot
                break
            }
        }

        #expect(finalFrame?.revision == 2)
        #expect(finalFrame.map { pixel($0, x: 0, y: 0) } == [10, 0, 0, 255])
        #expect(finalFrame.map { pixel($0, x: 2, y: 0) } == [70, 0, 0, 255])
        runTask.cancel()
        _ = try? await runTask.value
        await channel.close()
    }

    @Test func sendsDisplayInitializationBeforeReceivingServerMessages() async throws {
        let transport = FakeTransport(inbound: [.failure(.connectionClosed)])
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        await #expect(throws: ChannelError.self) {
            try await channel.run { _ in }
        }

        let framed = try #require((await transport.outbound).first)
        var reader = try ByteReader(framed)
        #expect(try reader.readUInt16LE() == 101)
        #expect(try reader.readUInt32LE() == 14)
        #expect(try reader.readUInt8() == 1)
        #expect(try reader.readUInt64LE() == 16 * 1_024 * 1_024)
        #expect(try reader.readUInt8() == 1)
        #expect(try reader.readInt32LE() == 8 * 1_024 * 1_024)
        #expect(reader.remainingCount == 0)
    }

    @Test func publishesAuthoritativeMonitorConfiguration() async throws {
        var body = ByteWriter()
        body.writeUInt16LE(2)
        body.writeUInt16LE(4)
        for values: [UInt32] in [
            [0, 10, 1_920, 1_080, 0, 0, 0],
            [1, 11, 1_280, 1_024, 1_920, 0, 0],
        ] {
            for value in values {
                body.writeUInt32LE(value)
            }
        }
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 317, body: body.data)),
        ])
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 3),
            transport: transport,
            headerMode: .mini
        ))

        let event = try await channel.processNext()
        guard case let .monitorsConfigured(configuration) = event else {
            Issue.record("expected monitors configuration")
            return
        }
        #expect(configuration.maximumAllowed == 4)
        #expect(configuration.monitors.map(\.id) == [0, 1])
        #expect(configuration.monitors[1].x == 1_920)
    }

    @Test func decodesStrictMJPEGStreamLifecycleWireBodies() throws {
        let createBody = streamCreateBody(
            streamID: 7,
            streamWidth: 2,
            streamHeight: 2,
            sourceWidth: 2,
            sourceHeight: 1,
            destination: (top: 0, left: 0, bottom: 2, right: 4),
            clipRectangles: [(top: 0, left: 0, bottom: 2, right: 2)]
        )
        let create = try SpiceDisplayWireDecoder().decodeStreamCreateMessage(createBody)
        #expect(create.surfaceID == 1)
        #expect(create.streamID == 7)
        #expect(create.topDown)
        #expect(create.codec == .mjpeg)
        #expect(create.streamWidth == 2)
        #expect(create.sourceHeight == 1)
        #expect(create.destination == SpiceRect(top: 0, left: 0, bottom: 2, right: 4))

        let dataBody = streamDataBody(streamID: 7, multimediaTime: 100, data: Data([1, 2]))
        let data = try SpiceDisplayWireDecoder().decodeStreamDataMessage(dataBody)
        #expect(data.streamID == 7)
        #expect(data.multimediaTime == 100)
        #expect(data.data == Data([1, 2]))

        let sizedBody = streamDataSizedBody(
            streamID: 7,
            multimediaTime: 101,
            width: 1,
            height: 1,
            destination: (top: 1, left: 2, bottom: 2, right: 4),
            data: Data([3])
        )
        let sized = try SpiceDisplayWireDecoder().decodeStreamDataSizedMessage(sizedBody)
        #expect(sized.width == 1)
        #expect(sized.height == 1)
        #expect(sized.data == Data([3]))

        let clipBody = streamClipBody(
            streamID: 7,
            rectangles: [(top: 0, left: 2, bottom: 2, right: 4)]
        )
        let clip = try SpiceDisplayWireDecoder().decodeStreamClipMessage(clipBody)
        #expect(clip.streamID == 7)
        #expect(clip.clip == .rectangles([
            SpiceRect(top: 0, left: 2, bottom: 2, right: 4),
        ]))
        #expect(try SpiceDisplayWireDecoder().decodeStreamDestroyMessage(
            streamDestroyBody(streamID: 7)
        ) == 7)
        try SpiceDisplayWireDecoder().decodeStreamDestroyAllMessage(Data())

        for length in 0..<createBody.count {
            #expect(throws: WireError.self) {
                try SpiceDisplayWireDecoder().decodeStreamCreateMessage(
                    Data(createBody.prefix(length))
                )
            }
        }
        var invalidID = createBody
        invalidID.replaceSubrange(4..<8, with: Data([64, 0, 0, 0]))
        #expect(throws: WireError.invalidSize(64)) {
            try SpiceDisplayWireDecoder().decodeStreamCreateMessage(invalidID)
        }
        var invalidFlags = createBody
        invalidFlags[8] = 2
        #expect(throws: WireError.self) {
            try SpiceDisplayWireDecoder().decodeStreamCreateMessage(invalidFlags)
        }
        var trailingData = dataBody
        trailingData.append(0)
        #expect(throws: WireError.self) {
            try SpiceDisplayWireDecoder().decodeStreamDataMessage(trailingData)
        }
    }

    @Test func presentsOrderedMJPEGFramesWithClipScalingAndSizedData() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 4,
                height: 4,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 4, right: 4),
                clipRectangles: [(top: 0, left: 0, bottom: 4, right: 2)]
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 10,
                data: Data([1])
            )),
            encodeMini(id: 124, body: streamClipBody(
                streamID: 7,
                rectangles: [(top: 0, left: 2, bottom: 4, right: 4)]
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 11,
                data: Data([2])
            )),
            encodeMini(id: 316, body: streamDataSizedBody(
                streamID: 7,
                multimediaTime: 12,
                width: 1,
                height: 1,
                destination: (top: 1, left: 2, bottom: 3, right: 4),
                data: Data([3])
            )),
            encodeMini(id: 125, body: streamDestroyBody(streamID: 7)),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 13,
                data: Data([4])
            )),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: PatternJPEGDecoder()
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == .ignored(122))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 1))
        #expect(try await channel.processNext() == .ignored(124))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 2))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 3))

        let snapshot = try await channel.snapshot(surfaceID: 1)
        #expect(pixel(snapshot, x: 0, y: 0) == [10, 0, 0, 255])
        #expect(pixel(snapshot, x: 1, y: 1) == [10, 0, 0, 255])
        #expect(pixel(snapshot, x: 0, y: 3) == [30, 0, 0, 255])
        #expect(pixel(snapshot, x: 2, y: 0) == [60, 0, 0, 255])
        #expect(pixel(snapshot, x: 3, y: 3) == [80, 0, 0, 255])
        #expect(pixel(snapshot, x: 2, y: 1) == [90, 0, 0, 255])
        #expect(pixel(snapshot, x: 3, y: 2) == [90, 0, 0, 255])

        #expect(try await channel.processNext() == .ignored(125))
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == snapshot)
    }

    @Test func streamCreationUsesSurfaceMetadataWithoutSnapshottingPixels() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 4,
                height: 4,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 4, right: 4),
                clipRectangles: nil
            )),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let store = SurfaceStore(backingPolicy: .dataOnly)
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            surfaces: store
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == .ignored(122))
        #expect(await store.metrics().snapshots == 0)
    }

    @Test func routesH264ThroughInjectedDecoderWithoutAdvertisingCapability() async throws {
        let decoder = StubAdvancedVideoDecoder(image: SpiceDecodedImage(
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixelsBGRA: Data([
                1, 2, 3, 255, 4, 5, 6, 255,
                7, 8, 9, 255, 10, 11, 12, 255,
            ])
        ))
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 8,
                codec: 3,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 8,
                multimediaTime: 42,
                data: Data([0, 0, 1, 0x65])
            )),
            encodeMini(id: 125, body: streamDestroyBody(streamID: 8)),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            advancedVideoDecoderFactory: StubAdvancedVideoDecoderFactory(decoder: decoder)
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == .ignored(122))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 1))
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            1, 2, 3, 255, 4, 5, 6, 255,
            7, 8, 9, 255, 10, 11, 12, 255,
        ]))
        #expect(await decoder.receivedPayloads == [Data([0, 0, 1, 0x65])])
        #expect(try await channel.processNext() == .ignored(125))
        #expect(await decoder.closeCount == 1)
        let diagnostics = await channel.diagnosticsSnapshot()
        #expect(diagnostics.advancedVideo.decodedFrameCount == 1)
        #expect(diagnostics.advancedCPUFallbackFrames == 1)
        #expect(diagnostics.surfaces.nativeVideoFallbacks == 1)
    }

    @Test func unavailableMetalDisablesUntilTheNextStreamGeneration() async throws {
        let decoder = StubAdvancedVideoDecoder(image: SpiceDecodedImage(
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixelsBGRA: Data(repeating: 0x7f, count: 16)
        ))
        let streamCreate = encodeMini(id: 122, body: streamCreateBody(
            streamID: 9,
            codec: 3,
            streamWidth: 2,
            streamHeight: 2,
            sourceWidth: 2,
            sourceHeight: 2,
            destination: (top: 0, left: 0, bottom: 2, right: 2),
            clipRectangles: nil
        ))
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
            streamCreate,
            encodeMini(id: 123, body: streamDataBody(
                streamID: 9,
                multimediaTime: 42,
                data: Data([1])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 9,
                multimediaTime: 43,
                data: Data([2])
            )),
            encodeMini(id: 125, body: streamDestroyBody(streamID: 9)),
            streamCreate,
            encodeMini(id: 123, body: streamDataBody(
                streamID: 9,
                multimediaTime: 44,
                data: Data([3])
            )),
            encodeMini(id: 125, body: streamDestroyBody(streamID: 9)),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let store = SurfaceStore(backingPolicy: .dataOnly)
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            surfaces: store,
            advancedVideoDecoderFactory: StubAdvancedVideoDecoderFactory(decoder: decoder)
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == .ignored(122))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 1))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 2))
        #expect(try await channel.processNext() == .ignored(125))
        #expect(try await channel.processNext() == .ignored(122))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 3))

        let diagnostics = await channel.diagnosticsSnapshot()
        #expect(diagnostics.advancedCPUFallbackFrames == 3)
        #expect(diagnostics.metalGenerationDisableCount == 2)
        #expect(
            diagnostics.firstMetalGenerationDisableReason?
                .contains("Metal compositor requires") == true
        )
        #expect(diagnostics.surfaces.nativeVideoFallbacks == 2)
        #expect(diagnostics.surfaces.compositorErrors == 0)
        #expect(await decoder.receivedPayloads == [Data([1]), Data([2]), Data([3])])
        #expect(try await channel.processNext() == .ignored(125))
    }

    @Test func submitsLateInterFrameVideoWithoutCommittingDecodedPixels() async throws {
        let decoder = StubAdvancedVideoDecoder(image: SpiceDecodedImage(
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixelsBGRA: Data(repeating: 0xaa, count: 16)
        ))
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 8,
                codec: 3,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 8,
                multimediaTime: 99,
                data: Data([0, 0, 1, 0x61])
            )),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            advancedVideoDecoderFactory: StubAdvancedVideoDecoderFactory(decoder: decoder),
            multimediaClock: RecordingDisplayMultimediaClock(initialTime: 100)
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == .ignored(122))
        #expect(try await channel.processNext() == .ignored(123))
        #expect(await decoder.receivedPayloads == [Data([0, 0, 1, 0x61])])
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data(repeating: 0, count: 16))
        await channel.close()
    }

    @Test func schedulesFutureMJPEGAndDropsLateFrameBeforeDecode() async throws {
        let clock = RecordingDisplayMultimediaClock(initialTime: 100)
        let decoder = CountingPatternJPEGDecoder()
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 100,
                data: Data([1])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 110,
                data: Data([2])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 109,
                data: Data([3])
            )),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            multimediaClock: clock
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == .ignored(122))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 1))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 2))
        let beforeLateFrame = try await channel.snapshot(surfaceID: 1)
        #expect(try await channel.processNext() == .ignored(123))

        #expect(await clock.waitedTargets == [100, 110])
        #expect(await decoder.decodeCount == 2)
        #expect(try await channel.snapshot(surfaceID: 1) == beforeLateFrame)
    }

    @Test func dropsMJPEGThatBecomesLateDuringDecodeWithoutSurfaceMutation() async throws {
        let clock = RecordingDisplayMultimediaClock(
            initialTime: 100,
            forcedLateWaitTargets: [110]
        )
        let decoder = CountingPatternJPEGDecoder()
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 7,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 7,
                multimediaTime: 110,
                data: Data([1])
            )),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: decoder,
            multimediaClock: clock
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == .ignored(122))
        let before = try await channel.snapshot(surfaceID: 1)
        #expect(try await channel.processNext() == .ignored(123))
        #expect(await decoder.decodeCount == 1)
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func boundsMJPEGStreamsAndKeepsFailedFramesTransactional() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 1,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 1,
                multimediaTime: 1,
                data: Data([0xff])
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 1,
                multimediaTime: 2,
                data: Data([1])
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 2,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 126, body: Data()),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 2,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 2,
                destination: (top: 0, left: 0, bottom: 2, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 2,
                multimediaTime: 3,
                data: Data([2])
            )),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: PatternJPEGDecoder(),
            maximumStreams: 1
        )

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 1))
        let committed = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == committed)
        #expect(try await channel.processNext() == .ignored(126))
        #expect(try await channel.processNext() == .ignored(122))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 2))
    }

    @Test func presentsBottomUpMJPEGRelativeToAdvertisedSourceHeight() async throws {
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 122, body: streamCreateBody(
                streamID: 3,
                topDown: false,
                streamWidth: 2,
                streamHeight: 2,
                sourceWidth: 2,
                sourceHeight: 1,
                destination: (top: 0, left: 0, bottom: 1, right: 2),
                clipRectangles: nil
            )),
            encodeMini(id: 123, body: streamDataBody(
                streamID: 3,
                multimediaTime: 1,
                data: Data([1])
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: PatternJPEGDecoder()
        )

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        _ = try await channel.processNext()
        let snapshot = try await channel.snapshot(surfaceID: 1)
        #expect(pixel(snapshot, x: 0, y: 0) == [10, 0, 0, 255])
        #expect(pixel(snapshot, x: 1, y: 0) == [20, 0, 0, 255])
    }

    @Test func zlibGLZFeedsSharedDictionaryAndRenders() async throws {
        let compressed = try #require(Data(base64Encoded:
            "eJxTUIjyYWBkYJRgYGBgAmJGIOZgQAKMjEzMLKxsACbTASI="
        ))
        let zlibBody = drawZlibGLZCopyBody(payload: compressed, glzDataSize: 40)
        let decoded = try SpiceDisplayWireDecoder().decode(id: 304, body: zlibBody)
        guard case let .drawCopy(copy) = decoded,
              case let .zlibGLZ(descriptor, data) = copy.sourceImage
        else {
            Issue.record("expected ZLIB_GLZ_RGB DRAW_COPY")
            return
        }
        #expect(descriptor.type == 107)
        #expect(data.glzDataSize == 40)
        #expect(data.data == compressed)

        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: zlibBody),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 102,
                payload: glzCrossImagePayload()
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        _ = try await channel.processNext()
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            1, 2, 3, 255, 4, 5, 6, 255,
        ]))
    }

    @Test func failedZlibGLZDoesNotPublishSurfaceOrDictionary() async throws {
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawZlibGLZCopyBody(
                payload: Data([1, 2, 3]),
                glzDataSize: 40
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 102,
                payload: glzCrossImagePayload()
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
        let missingReference = Task {
            try await channel.processNext()
        }
        await Task.yield()
        missingReference.cancel()
        await #expect(throws: ChannelError.self) {
            try await missingReference.value
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func decodesAndCommitsGLZRGBWireBody() async throws {
        let payload = glzLiteralPayload()
        let body = drawCompressedCopyBody(imageType: 102, payload: payload)
        let decoded = try SpiceDisplayWireDecoder().decode(id: 304, body: body)
        guard case let .drawCopy(copy) = decoded,
              case let .glzRGB(descriptor, data) = copy.sourceImage
        else {
            Issue.record("expected GLZ_RGB DRAW_COPY")
            return
        }
        #expect(descriptor.type == 102)
        #expect(data == payload)

        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: body),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            1, 2, 3, 255, 4, 5, 6, 255,
        ]))
    }

    @Test func rebindingPreservesSurfaceAndDecodedImageCache() async throws {
        let cachedReference = drawCachedCopyBody(imageType: 103, descriptorID: 0x4455)
        let decoded = try SpiceDisplayWireDecoder().decode(id: 304, body: cachedReference)
        guard case let .drawCopy(copy) = decoded,
              case let .cached(descriptor, requirement) = copy.sourceImage
        else {
            Issue.record("expected cached image reference")
            return
        }
        #expect(descriptor.id == 0x4455)
        #expect(requirement == .any)

        let source = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 101,
                payload: Data([1]),
                descriptorID: 0x4455,
                descriptorFlags: 0x01
            )),
        ].map(Result.success))
        try await source.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: source,
                headerMode: .mini
            ),
            lzDecoder: StubLZDecoder(result: .success(decodedPixels([1, 2, 3, 4, 5, 6])))
        )

        _ = try await channel.processNext()
        _ = try await channel.processNext()

        let target = FakeTransport(inbound: [
            .success(encodeMini(id: 304, body: cachedReference)),
        ])
        try await target.connect()
        _ = try await channel.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: target,
            headerMode: .mini
        ))
        _ = try await channel.processNext()
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            1, 2, 3, 255, 4, 5, 6, 255,
        ]))
    }

    @Test func losslessReferenceRejectsJPEGUntilLosslessReplacement() async throws {
        let imageID: UInt64 = 0x7788
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 105,
                payload: Data([1]),
                descriptorID: imageID,
                descriptorFlags: 0x01
            )),
            encodeMini(id: 304, body: drawCachedCopyBody(
                imageType: 106,
                descriptorID: imageID
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: StubJPEGDecoder(result: .success(decodedPixels([9, 8, 7, 6, 5, 4])))
        )

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func replacesLossyCacheWithLosslessImage() async throws {
        let imageID: UInt64 = 0x99aa
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 105,
                payload: Data([1]),
                descriptorID: imageID,
                descriptorFlags: 0x01
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 101,
                payload: Data([2]),
                descriptorID: imageID,
                descriptorFlags: 0x04
            )),
            encodeMini(id: 304, body: drawCachedCopyBody(
                imageType: 106,
                descriptorID: imageID
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: StubJPEGDecoder(result: .success(decodedPixels([9, 8, 7, 6, 5, 4]))),
            lzDecoder: StubLZDecoder(result: .success(decodedPixels([1, 2, 3, 4, 5, 6])))
        )

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        _ = try await channel.processNext()
        _ = try await channel.processNext()
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            1, 2, 3, 255, 4, 5, 6, 255,
        ]))
    }

    @Test func invalidationMessagesRemoveSharedImages() async throws {
        for (messageID, invalidationBody): (UInt16, Data) in [
            (105, invalidateImagesBody([0x1234])),
            (106, invalidateAllImagesBody()),
        ] {
            let transport = FakeTransport(inbound: try [
                encodeMini(SpiceMsgDisplaySurfaceCreate(
                    surfaceID: 1,
                    width: 2,
                    height: 1,
                    format: 32,
                    flags: 1
                )),
                encodeMini(id: 304, body: drawCompressedCopyBody(
                    imageType: 101,
                    payload: Data([1]),
                    descriptorID: 0x1234,
                    descriptorFlags: 0x01
                )),
                encodeMini(id: messageID, body: invalidationBody),
                encodeMini(id: 304, body: drawCachedCopyBody(
                    imageType: 103,
                    descriptorID: 0x1234
                )),
            ].map(Result.success))
            try await transport.connect()
            let channel = DisplayChannel(
                connection: ChannelConnection(
                    key: ChannelKey(type: 2, id: 0),
                    transport: transport,
                    headerMode: .mini
                ),
                lzDecoder: StubLZDecoder(
                    result: .success(decodedPixels([1, 2, 3, 4, 5, 6]))
                )
            )

            _ = try await channel.processNext()
            _ = try await channel.processNext()
            _ = try await channel.processNext()
            let before = try await channel.snapshot(surfaceID: 1)
            await #expect(throws: ChannelError.self) {
                try await channel.processNext()
            }
            #expect(try await channel.snapshot(surfaceID: 1) == before)
        }
    }

    @Test func displayResetPreservesSessionSharedImageCache() async throws {
        let imageID: UInt64 = 0x2468
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 101,
                payload: Data([1]),
                descriptorID: imageID,
                descriptorFlags: 0x01
            )),
            encodeMini(id: 103, body: Data()),
            encodeMini(id: 304, body: drawCachedCopyBody(
                imageType: 103,
                descriptorID: imageID
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            lzDecoder: StubLZDecoder(result: .success(decodedPixels([1, 2, 3, 4, 5, 6])))
        )

        for _ in 0..<4 {
            _ = try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            1, 2, 3, 255, 4, 5, 6, 255,
        ]))
    }

    @Test func repeatedCacheMeUsesReferenceCountedInvalidation() async throws {
        let imageID: UInt64 = 0x5678
        let invalidation = invalidateImagesBody([imageID])
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 101,
                payload: Data([1]),
                descriptorID: imageID,
                descriptorFlags: 0x01
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 105,
                payload: Data([2]),
                descriptorID: imageID,
                descriptorFlags: 0x01
            )),
            encodeMini(id: 105, body: invalidation),
            encodeMini(id: 304, body: drawCachedCopyBody(
                imageType: 103,
                descriptorID: imageID
            )),
            encodeMini(id: 105, body: invalidation),
            encodeMini(id: 304, body: drawCachedCopyBody(
                imageType: 103,
                descriptorID: imageID
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: StubJPEGDecoder(result: .success(decodedPixels([9, 8, 7, 6, 5, 4]))),
            lzDecoder: StubLZDecoder(result: .success(decodedPixels([1, 2, 3, 4, 5, 6])))
        )

        for _ in 0..<6 {
            _ = try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            9, 8, 7, 255, 6, 5, 4, 255,
        ]))
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
    }

    @Test func failedDecodeAndCacheLimitDoNotPublishImages() async throws {
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 101,
                payload: Data([1]),
                descriptorID: 1,
                descriptorFlags: 0x01
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 105,
                payload: Data([2]),
                descriptorID: 2,
                descriptorFlags: 0x01
            )),
            encodeMini(id: 304, body: drawCachedCopyBody(
                imageType: 103,
                descriptorID: 2
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: StubJPEGDecoder(result: .success(decodedPixels([9, 8, 7, 6, 5, 4]))),
            lzDecoder: StubLZDecoder(result: .success(decodedPixels([1, 2, 3, 4, 5, 6]))),
            maximumCachedImages: 1
        )

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
    }

    @Test func decodesAndCommitsRealQUICWithBottomUpRows() async throws {
        let compressed = try #require(Data(base64Encoded:
            "UVVJQwAAAAADAAAABwAAAAUAAAAAgICAAAARAAAAQADrWlqj21pvW9bb1noBut62UlVc1+PJalyyGk9WD5DVeNOvJavjKWqcshpPVsaT1XhZfYCsGuf9OpPVeIo1nqzGIKvxZL9OVh+eosZ5q/FkNTxZjSdW48lqAAAAQAAAAAA="
        ))
        let reference = try #require(Data(base64Encoded:
            "AAAAAB0LKwA6FlYAVyGBAHQsrACRN9cArkICAAcfDQAkKjgAQTVjAF5AjgB7S7kAmFbkALVhDwAOPhoAK0lFAEhUcABlX5sAgmrGAJ918QC8gBwAFV0nADJoUgBPc30AbH6oAImJ0wCmlP4Aw58pABx8NAA5h18AVpKKAHOdtQCQqOAArbMLAMq+NgA="
        ))
        let body = drawCompressedCopyBody(
            imageType: 1,
            payload: compressed,
            width: 7,
            height: 5
        )
        let decodedWire = try SpiceDisplayWireDecoder().decode(id: 304, body: body)
        guard case let .drawCopy(copy) = decodedWire,
              case let .quic(descriptor, data) = copy.sourceImage
        else {
            Issue.record("expected QUIC DRAW_COPY")
            return
        }
        #expect(descriptor.type == 1)
        #expect(data == compressed)

        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 7,
                height: 5,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: body),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.processNext()
        _ = try await channel.processNext()

        var expected = Data(capacity: reference.count)
        let rowBytes = 7 * 4
        for row in (0..<5).reversed() {
            expected.append(reference[(row * rowBytes)..<((row + 1) * rowBytes)])
        }
        for alphaOffset in stride(from: 3, to: expected.count, by: 4) {
            expected[alphaOffset] = 0xff
        }
        #expect(try await channel.snapshot(surfaceID: 1).pixels == expected)
    }

    @Test func malformedQUICDoesNotPolluteSurface() async throws {
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 1,
                payload: Data([0, 0, 0, 0])
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func decodesInlineAndCachedLZPaletteWireBodies() throws {
        let payload = literalPLT8Payload()
        let inlineBody = drawPaletteCopyBody(
            flags: 0x01,
            paletteID: 0x1122,
            entries: [0x0011_2233, 0x0044_5566],
            payload: payload
        )
        let decoded = try SpiceDisplayWireDecoder().decode(id: 304, body: inlineBody)
        guard case let .drawCopy(copy) = decoded,
              case let .lzPalette(descriptor, data) = copy.sourceImage,
              case let .inline(palette) = data.palette
        else {
            Issue.record("expected inline LZ palette")
            return
        }
        #expect(descriptor.type == 100)
        #expect(data.flags == 0x01)
        #expect(data.data == payload)
        #expect(palette.uniqueID == 0x1122)
        #expect(palette.entriesARGB == [0x0011_2233, 0x0044_5566])

        let cachedBody = drawPaletteCopyBody(
            flags: 0x02,
            paletteID: 0x1122,
            entries: [],
            payload: payload
        )
        let cached = try SpiceDisplayWireDecoder().decode(id: 304, body: cachedBody)
        guard case let .drawCopy(cachedCopy) = cached,
              case let .lzPalette(_, cachedData) = cachedCopy.sourceImage,
              case let .cached(id) = cachedData.palette
        else {
            Issue.record("expected cached LZ palette")
            return
        }
        #expect(id == 0x1122)

        var badPointer = inlineBody
        let palettePointerOffset = inlineBody.count
            - (8 + 2 + palette.entriesARGB.count * 4)
            - payload.count
            - 4
        badPointer.replaceSubrange(
            palettePointerOffset..<(palettePointerOffset + 4),
            with: Data(repeating: 0, count: 4)
        )
        #expect(throws: WireError.self) {
            try SpiceDisplayWireDecoder().decode(id: 304, body: badPointer)
        }
    }

    @Test func cachesPaletteThenHonorsEveryInvalidationMessage() async throws {
        for invalidationID: UInt16 in [107, 108, 103] {
            let paletteID: UInt64 = 0x1122
            let payload = literalPLT8Payload()
            let invalidationBody: Data
            if invalidationID == 107 {
                var writer = ByteWriter()
                writer.writeUInt64LE(paletteID)
                invalidationBody = writer.data
            } else {
                invalidationBody = Data()
            }
            let transport = FakeTransport(inbound: try [
                encodeMini(SpiceMsgDisplaySurfaceCreate(
                    surfaceID: 1,
                    width: 2,
                    height: 1,
                    format: 32,
                    flags: 1
                )),
                encodeMini(id: 304, body: drawPaletteCopyBody(
                    flags: 0x01,
                    paletteID: paletteID,
                    entries: [0x0011_2233, 0x0044_5566],
                    payload: payload
                )),
                encodeMini(id: 304, body: drawPaletteCopyBody(
                    flags: 0x02,
                    paletteID: paletteID,
                    entries: [],
                    payload: payload
                )),
                encodeMini(id: invalidationID, body: invalidationBody),
                encodeMini(id: 304, body: drawPaletteCopyBody(
                    flags: 0x02,
                    paletteID: paletteID,
                    entries: [],
                    payload: payload
                )),
            ].map(Result.success))
            try await transport.connect()
            let channel = DisplayChannel(connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ))

            _ = try await channel.processNext()
            _ = try await channel.processNext()
            _ = try await channel.processNext()
            #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
                0x33, 0x22, 0x11, 0xff, 0x66, 0x55, 0x44, 0xff,
            ]))
            _ = try await channel.processNext()
            let beforeFailure = try await channel.snapshot(surfaceID: 1)
            await #expect(throws: ChannelError.self) {
                try await channel.processNext()
            }
            #expect(try await channel.snapshot(surfaceID: 1) == beforeFailure)
        }
    }

    @Test func failedPaletteDecodeDoesNotPopulateCacheOrSurface() async throws {
        let paletteID: UInt64 = 0x3344
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawPaletteCopyBody(
                flags: 0x01,
                paletteID: paletteID,
                entries: [0x0011_2233, 0x0044_5566],
                payload: Data([0x20, 0x20, 0x5a, 0x4c])
            )),
            encodeMini(id: 304, body: drawPaletteCopyBody(
                flags: 0x02,
                paletteID: paletteID,
                entries: [],
                payload: literalPLT8Payload()
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func rejectsPaletteCacheGrowthBeforeSurfaceMutation() async throws {
        let payload = literalPLT8Payload()
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawPaletteCopyBody(
                flags: 0x01,
                paletteID: 1,
                entries: [0x0011_2233, 0x0044_5566],
                payload: payload
            )),
            encodeMini(id: 304, body: drawPaletteCopyBody(
                flags: 0x01,
                paletteID: 2,
                entries: [0x00aa_bbcc, 0x00dd_eeff],
                payload: payload
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            maximumCachedPalettes: 1
        )

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func decodesAndCommitsLZRGB() async throws {
        let payload = Data([0x20, 0x20, 0x5a, 0x4c])
        let body = drawCompressedCopyBody(imageType: 101, payload: payload)
        let decoded = try SpiceDisplayWireDecoder().decode(id: 304, body: body)
        guard case let .drawCopy(copy) = decoded,
              case let .lzRGB(descriptor, data) = copy.sourceImage
        else {
            Issue.record("expected LZ_RGB DRAW_COPY")
            return
        }
        #expect(descriptor.type == 101)
        #expect(data == payload)

        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: body),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            lzDecoder: StubLZDecoder(result: .success(SpiceDecodedImage(
                width: 2,
                height: 1,
                bytesPerRow: 8,
                pixelsBGRA: Data([1, 2, 3, 0, 4, 5, 6, 0])
            )))
        )
        _ = try await channel.processNext()
        _ = try await channel.processNext()
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            1, 2, 3, 255, 4, 5, 6, 255,
        ]))
    }

    @Test func decodesRGBAThroughRealLZAndPreservesAlphaOnARGBSurface() async throws {
        let lzRGBA = Data([
            0x20, 0x20, 0x5a, 0x4c, 0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08,
            0x00, 0x00, 0x00, 0x01,
            0x01, 1, 2, 3, 4, 5, 6,
            0x01, 0x40, 0x80,
        ])
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 96,
                flags: 1
            )),
            encodeMini(id: 304, body: drawCompressedCopyBody(imageType: 101, payload: lzRGBA)),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        #expect(try await channel.snapshot(surfaceID: 1).pixels == Data([
            1, 2, 3, 0x40, 4, 5, 6, 0x80,
        ]))
    }

    @Test func malformedLZDoesNotPolluteSurface() async throws {
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 4,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 302, body: drawFillBody()),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 101,
                payload: Data([0x20, 0x20, 0x5a, 0x4c])
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func decodesJPEGBinaryPayloadWithStrictLength() throws {
        let payload = Data([0xff, 0xd8, 0xff, 0xd9])
        let body = drawJPEGCopyBody(payload: payload)
        let decoded = try SpiceDisplayWireDecoder().decode(id: 304, body: body)
        guard case let .drawCopy(copy) = decoded,
              case let .jpeg(descriptor, data) = copy.sourceImage
        else {
            Issue.record("expected JPEG DRAW_COPY")
            return
        }
        #expect(descriptor.type == 105)
        #expect(descriptor.width == 2)
        #expect(descriptor.height == 1)
        #expect(data == payload)

        var truncated = body
        truncated.removeLast()
        #expect(throws: WireError.self) {
            try SpiceDisplayWireDecoder().decode(id: 304, body: truncated)
        }
    }

    @Test func commitsJPEGOnlyAfterSuccessfulDecode() async throws {
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 2,
                height: 1,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 304, body: drawJPEGCopyBody(payload: Data([1, 2, 3]))),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: StubJPEGDecoder(result: .success(SpiceDecodedImage(
                width: 2,
                height: 1,
                bytesPerRow: 8,
                pixelsBGRA: Data([1, 2, 3, 255, 4, 5, 6, 255])
            )))
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 1))
        let snapshot = try await channel.snapshot(surfaceID: 1)
        #expect(snapshot.pixels == Data([1, 2, 3, 255, 4, 5, 6, 255]))
    }

    @Test func failedJPEGDecodeDoesNotPolluteSurface() async throws {
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 4,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 302, body: drawFillBody()),
            encodeMini(id: 304, body: drawJPEGCopyBody(payload: Data([0xff, 0xd8]))),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            jpegDecoder: StubJPEGDecoder(result: .failure(.decodeFailed))
        )

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func turboJPEGWarningDoesNotPolluteSurface() async throws {
        var warningJPEG = try #require(Data(base64Encoded:
            "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAAIAAgDAREAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwCP/g3f+C3/AA31/wANf/8AFS/8Kn/4VP8A8M//APMG/wCE7/t//hO/+F2f9RXwb/ZX9lf8Ib/1Eft39pf8uf2P/Sj9ph+wz/4ly/4gp/x1F/rl/rl/xEj/AJsn/q9/Z3+r3+oX/V3M8+ufXP7c/wCoX6v9V/5f+3/cz+2C8Sv+K0f/ABLv/wAIv/Etn/Etn/EW/wDmZf8AEYv9dP8AiMX/ABDL/qA8LP8AVz/Vz/iFn/U9/tf+3f8AmV/2X/wo/wD/2Q=="
        ))
        #expect(warningJPEG.suffix(2) == Data([0xFF, 0xD9]))
        warningJPEG.removeLast(2)
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 8,
                height: 8,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 302, body: drawFillBody()),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 105,
                payload: warningJPEG,
                width: 8,
                height: 8
            )),
        ].map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        _ = try await channel.processNext()
        _ = try await channel.processNext()
        let before = try await channel.snapshot(surfaceID: 1)
        await #expect(throws: ChannelError.self) {
            try await channel.processNext()
        }
        #expect(try await channel.snapshot(surfaceID: 1) == before)
    }

    @Test func executesSurfaceFillRawCopyAndCopyBits() async throws {
        let inbound = try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 4,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(id: 302, body: drawFillBody()),
            encodeMini(id: 304, body: drawCopyBody()),
            encodeMini(id: 104, body: copyBitsBody()),
            encodeMini(SpiceMsgDisplaySurfaceDestroy(surfaceID: 1)),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        )
        let channel = DisplayChannel(connection: connection)

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 1))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 2))
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 3))

        let snapshot = try await channel.snapshot(surfaceID: 1)
        #expect(pixel(snapshot, x: 0, y: 0) == [0, 0, 255, 255])
        #expect(pixel(snapshot, x: 1, y: 0) == [0, 0, 255, 255])
        #expect(pixel(snapshot, x: 2, y: 0) == [1, 2, 3, 255])
        #expect(pixel(snapshot, x: 3, y: 0) == [4, 5, 6, 255])
        #expect(pixel(snapshot, x: 0, y: 1) == [1, 2, 3, 255])
        #expect(pixel(snapshot, x: 1, y: 1) == [4, 5, 6, 255])
        #expect(pixel(snapshot, x: 2, y: 1) == [7, 8, 9, 255])
        #expect(pixel(snapshot, x: 3, y: 1) == [10, 11, 12, 255])

        #expect(try await channel.processNext() == .surfaceDestroyed(1))
    }

    @Test func fullyClippedCommandsDoNotPublishButStillCacheAndAcknowledge() async throws {
        let imageID: UInt64 = 0x4455
        let transport = FakeTransport(inbound: try [
            encodeMini(SpiceMsgDisplaySurfaceCreate(
                surfaceID: 1,
                width: 4,
                height: 2,
                format: 32,
                flags: 1
            )),
            encodeMini(SpiceMsgSetAck(generation: 7, window: 1)),
            encodeMini(id: 302, body: drawFillBody(clipRectangles: [])),
            encodeMini(id: 104, body: copyBitsBody(clipRectangles: [])),
            encodeMini(id: 304, body: drawCompressedCopyBody(
                imageType: 101,
                payload: Data([1]),
                descriptorID: imageID,
                descriptorFlags: 0x01,
                clipRectangles: []
            )),
            encodeMini(id: 304, body: drawCachedCopyBody(
                imageType: 103,
                descriptorID: imageID
            )),
        ].map(Result.success))
        try await transport.connect()
        let store = SurfaceStore(backingPolicy: .dataOnly)
        let channel = DisplayChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 2, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            surfaces: store,
            lzDecoder: StubLZDecoder(
                result: .success(decodedPixels([1, 2, 3, 4, 5, 6]))
            )
        )

        #expect(try await channel.processNext() == .surfaceCreated(1))
        #expect(try await channel.processNext() == .ignored(3))
        #expect(try await channel.processNext() == .ignored(302))
        #expect(try await channel.processNext() == .ignored(104))
        #expect(try await channel.processNext() == .ignored(304))
        #expect(try await store.descriptor(surfaceID: 1).revision == 0)
        #expect(try await channel.processNext() == frameChanged(surfaceID: 1, revision: 1))
        #expect(try await channel.snapshot(surfaceID: 1).pixels.prefix(8) == Data([
            1, 2, 3, 255, 4, 5, 6, 255,
        ]))

        let outbound = await transport.outbound
        #expect(try outbound.map(miniMessageID) == [1, 2, 2, 2, 2])
    }

    @Test func rejectsImagePointerIntoFixedMessageBody() throws {
        var body = drawCopyBody()
        body.replaceSubrange(21..<25, with: Data([1, 0, 0, 0]))
        #expect(throws: WireError.invalidOffset(1)) {
            try SpiceDisplayWireDecoder().decode(id: 304, body: body)
        }
    }

    @Test func decodesPatternBrushAndMaskPointerImages() throws {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (top: 0, left: 0, bottom: 1, right: 1),
            clipRectangles: nil
        )
        let fixedSize = writer.data.count + 13 + 2 + 13
        writer.writeUInt8(2) // SPICE_BRUSH_TYPE_PATTERN
        writer.writeUInt32LE(UInt32(fixedSize))
        writer.writeInt32LE(4)
        writer.writeInt32LE(5)
        writer.writeUInt16LE(0x08)
        writer.writeUInt8(0)
        writer.writeInt32LE(0)
        writer.writeInt32LE(0)
        writer.writeUInt32LE(UInt32(fixedSize + 22))
        writeSurfaceImage(to: &writer, descriptorID: 10, surfaceID: 2)
        writeSurfaceImage(to: &writer, descriptorID: 11, surfaceID: 3)

        let decoded = try SpiceDisplayWireDecoder().decode(id: 302, body: writer.data)
        guard case let .drawFill(fill) = decoded else {
            Issue.record("expected DRAW_FILL")
            return
        }
        guard case let .pattern(image, position) = fill.brush else {
            Issue.record("expected pattern brush")
            return
        }
        #expect(position == SpicePoint(x: 4, y: 5))
        guard case let .surface(_, patternSurfaceID) = image else {
            Issue.record("expected surface pattern image")
            return
        }
        #expect(patternSurfaceID == 2)
        guard case let .surface(_, maskSurfaceID) = fill.mask.bitmap else {
            Issue.record("expected surface mask image")
            return
        }
        #expect(maskSurfaceID == 3)
    }

    @Test func rejectsClipCountBeyondAvailableBody() {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (top: 0, left: 0, bottom: 1, right: 1),
            clipRectangles: []
        )
        // Rewrite the inline clip count to claim a rectangle that is absent.
        var body = writer.data
        body.replaceSubrange(21..<25, with: Data([1, 0, 0, 0]))
        #expect(throws: WireError.invalidSize(1)) {
            try SpiceDisplayWireDecoder().decode(id: 104, body: body)
        }
    }

    private func drawFillBody(
        clipRectangles: [(top: Int32, left: Int32, bottom: Int32, right: Int32)] = [
            (top: 0, left: 0, bottom: 2, right: 2),
        ]
    ) -> Data {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (top: 0, left: 0, bottom: 2, right: 4),
            clipRectangles: clipRectangles
        )
        writer.writeUInt8(1) // SPICE_BRUSH_TYPE_SOLID
        writer.writeUInt32LE(0x00ff_0000)
        writer.writeUInt16LE(0x08) // SPICE_ROPD_OP_PUT
        writeEmptyMask(to: &writer)
        return writer.data
    }

    private func streamCreateBody(
        streamID: UInt32,
        codec: UInt8 = 1,
        topDown: Bool = true,
        streamWidth: UInt32,
        streamHeight: UInt32,
        sourceWidth: UInt32,
        sourceHeight: UInt32,
        destination: (top: Int32, left: Int32, bottom: Int32, right: Int32),
        clipRectangles: [(top: Int32, left: Int32, bottom: Int32, right: Int32)]?
    ) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(1)
        writer.writeUInt32LE(streamID)
        writer.writeUInt8(topDown ? 1 : 0)
        writer.writeUInt8(codec)
        writer.writeUInt64LE(0)
        writer.writeUInt32LE(streamWidth)
        writer.writeUInt32LE(streamHeight)
        writer.writeUInt32LE(sourceWidth)
        writer.writeUInt32LE(sourceHeight)
        writeRect(to: &writer, destination)
        writeClip(to: &writer, rectangles: clipRectangles)
        return writer.data
    }

    private func streamDataBody(
        streamID: UInt32,
        multimediaTime: UInt32,
        data: Data
    ) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(streamID)
        writer.writeUInt32LE(multimediaTime)
        writer.writeUInt32LE(UInt32(data.count))
        writer.writeBytes(data)
        return writer.data
    }

    private func streamDataSizedBody(
        streamID: UInt32,
        multimediaTime: UInt32,
        width: UInt32,
        height: UInt32,
        destination: (top: Int32, left: Int32, bottom: Int32, right: Int32),
        data: Data
    ) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(streamID)
        writer.writeUInt32LE(multimediaTime)
        writer.writeUInt32LE(width)
        writer.writeUInt32LE(height)
        writeRect(to: &writer, destination)
        writer.writeUInt32LE(UInt32(data.count))
        writer.writeBytes(data)
        return writer.data
    }

    private func streamClipBody(
        streamID: UInt32,
        rectangles: [(top: Int32, left: Int32, bottom: Int32, right: Int32)]?
    ) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(streamID)
        writeClip(to: &writer, rectangles: rectangles)
        return writer.data
    }

    private func streamDestroyBody(streamID: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(streamID)
        return writer.data
    }

    private func writeClip(
        to writer: inout ByteWriter,
        rectangles: [(top: Int32, left: Int32, bottom: Int32, right: Int32)]?
    ) {
        if let rectangles {
            writer.writeUInt8(1)
            writer.writeUInt32LE(UInt32(rectangles.count))
            for rectangle in rectangles {
                writeRect(to: &writer, rectangle)
            }
        } else {
            writer.writeUInt8(0)
        }
    }

    private func drawCopyBody() -> Data {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (top: 0, left: 2, bottom: 2, right: 4),
            clipRectangles: nil
        )
        let imageOffset = UInt32(writer.data.count + 36)
        writer.writeUInt32LE(imageOffset)
        writeRect(to: &writer, (top: 0, left: 0, bottom: 2, right: 2))
        writer.writeUInt16LE(0x08) // SPICE_ROPD_OP_PUT
        writer.writeUInt8(0) // interpolate; no scaling is required
        writeEmptyMask(to: &writer)

        writer.writeUInt64LE(55) // descriptor id
        writer.writeUInt8(0) // SPICE_IMAGE_TYPE_BITMAP
        writer.writeUInt8(0) // descriptor flags
        writer.writeUInt32LE(2)
        writer.writeUInt32LE(2)
        writer.writeUInt8(8) // SPICE_BITMAP_FMT_32BIT
        writer.writeUInt8(0x04) // SPICE_BITMAP_FLAGS_TOP_DOWN
        writer.writeUInt32LE(2)
        writer.writeUInt32LE(2)
        writer.writeUInt32LE(8)
        writer.writeUInt32LE(0) // no palette for true-color bitmap
        writer.writeBytes(Data([
            1, 2, 3, 0, 4, 5, 6, 0,
            7, 8, 9, 0, 10, 11, 12, 0,
        ]))
        return writer.data
    }

    private func drawJPEGCopyBody(payload: Data) -> Data {
        drawCompressedCopyBody(imageType: 105, payload: payload)
    }

    private func literalPLT8Payload() -> Data {
        Data([
            0x20, 0x20, 0x5a, 0x4c, 0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x01,
            0x01, 0x00, 0x01,
        ])
    }

    private func glzLiteralPayload() -> Data {
        Data([
            0x20, 0x20, 0x5a, 0x4c, 0x00, 0x01, 0x00, 0x01,
            0x18,
            0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x08,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x01, 1, 2, 3, 4, 5, 6,
        ])
    }

    private func glzCrossImagePayload() -> Data {
        Data([
            0x20, 0x20, 0x5a, 0x4c, 0x00, 0x01, 0x00, 0x01,
            0x18,
            0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x08,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0x40, 0x00, 0x01,
        ])
    }

    private func drawZlibGLZCopyBody(
        payload: Data,
        glzDataSize: UInt32
    ) -> Data {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (top: 0, left: 0, bottom: 1, right: 2),
            clipRectangles: nil
        )
        let imageOffset = UInt32(writer.data.count + 36)
        writer.writeUInt32LE(imageOffset)
        writeRect(to: &writer, (top: 0, left: 0, bottom: 1, right: 2))
        writer.writeUInt16LE(0x08)
        writer.writeUInt8(0)
        writeEmptyMask(to: &writer)
        writer.writeUInt64LE(90)
        writer.writeUInt8(107)
        writer.writeUInt8(0)
        writer.writeUInt32LE(2)
        writer.writeUInt32LE(1)
        writer.writeUInt32LE(glzDataSize)
        writer.writeUInt32LE(UInt32(payload.count))
        writer.writeBytes(payload)
        return writer.data
    }

    private func drawPaletteCopyBody(
        flags: UInt8,
        paletteID: UInt64,
        entries: [UInt32],
        payload: Data
    ) -> Data {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (top: 0, left: 0, bottom: 1, right: 2),
            clipRectangles: nil
        )
        let imageOffset = UInt32(writer.data.count + 36)
        writer.writeUInt32LE(imageOffset)
        writeRect(to: &writer, (top: 0, left: 0, bottom: 1, right: 2))
        writer.writeUInt16LE(0x08)
        writer.writeUInt8(0)
        writeEmptyMask(to: &writer)

        writer.writeUInt64LE(89)
        writer.writeUInt8(100)
        writer.writeUInt8(0)
        writer.writeUInt32LE(2)
        writer.writeUInt32LE(1)
        writer.writeUInt8(flags)
        writer.writeUInt32LE(UInt32(payload.count))
        if flags & 0x02 != 0 {
            writer.writeUInt64LE(paletteID)
            writer.writeBytes(payload)
        } else {
            let paletteOffset = UInt32(writer.data.count + 4 + payload.count)
            writer.writeUInt32LE(paletteOffset)
            writer.writeBytes(payload)
            writer.writeUInt64LE(paletteID)
            writer.writeUInt16LE(UInt16(entries.count))
            for entry in entries {
                writer.writeUInt32LE(entry)
            }
        }
        return writer.data
    }

    private func drawCompressedCopyBody(
        imageType: UInt8,
        payload: Data,
        width: UInt32 = 2,
        height: UInt32 = 1,
        descriptorID: UInt64 = 88,
        descriptorFlags: UInt8 = 0,
        clipRectangles: [(top: Int32, left: Int32, bottom: Int32, right: Int32)]? = nil
    ) -> Data {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (
                top: 0,
                left: 0,
                bottom: Int32(height),
                right: Int32(width)
            ),
            clipRectangles: clipRectangles
        )
        let imageOffset = UInt32(writer.data.count + 36)
        writer.writeUInt32LE(imageOffset)
        writeRect(to: &writer, (
            top: 0,
            left: 0,
            bottom: Int32(height),
            right: Int32(width)
        ))
        writer.writeUInt16LE(0x08)
        writer.writeUInt8(0)
        writeEmptyMask(to: &writer)

        writer.writeUInt64LE(descriptorID)
        writer.writeUInt8(imageType)
        writer.writeUInt8(descriptorFlags)
        writer.writeUInt32LE(width)
        writer.writeUInt32LE(height)
        writer.writeUInt32LE(UInt32(payload.count))
        writer.writeBytes(payload)
        return writer.data
    }

    private func drawCachedCopyBody(
        imageType: UInt8,
        descriptorID: UInt64,
        width: UInt32 = 2,
        height: UInt32 = 1
    ) -> Data {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (top: 0, left: 0, bottom: Int32(height), right: Int32(width)),
            clipRectangles: nil
        )
        let imageOffset = UInt32(writer.data.count + 36)
        writer.writeUInt32LE(imageOffset)
        writeRect(to: &writer, (
            top: 0,
            left: 0,
            bottom: Int32(height),
            right: Int32(width)
        ))
        writer.writeUInt16LE(0x08)
        writer.writeUInt8(0)
        writeEmptyMask(to: &writer)
        writer.writeUInt64LE(descriptorID)
        writer.writeUInt8(imageType)
        writer.writeUInt8(0)
        writer.writeUInt32LE(width)
        writer.writeUInt32LE(height)
        return writer.data
    }

    private func invalidateImagesBody(_ ids: [UInt64]) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(UInt16(ids.count))
        for id in ids {
            writer.writeUInt8(1) // SPICE_RES_TYPE_PIXMAP
            writer.writeUInt64LE(id)
        }
        return writer.data
    }

    private func invalidateAllImagesBody() -> Data {
        var writer = ByteWriter()
        writer.writeUInt8(0)
        return writer.data
    }

    private func decodedPixels(_ bgr: [UInt8]) -> SpiceDecodedImage {
        SpiceDecodedImage(
            width: 2,
            height: 1,
            bytesPerRow: 8,
            pixelsBGRA: Data([
                bgr[0], bgr[1], bgr[2], 0,
                bgr[3], bgr[4], bgr[5], 0,
            ])
        )
    }

    private func copyBitsBody(
        clipRectangles: [(top: Int32, left: Int32, bottom: Int32, right: Int32)]? = nil
    ) -> Data {
        var writer = ByteWriter()
        writeBase(
            to: &writer,
            surfaceID: 1,
            box: (top: 1, left: 0, bottom: 2, right: 2),
            clipRectangles: clipRectangles
        )
        writer.writeInt32LE(2)
        writer.writeInt32LE(0)
        return writer.data
    }

    private func writeBase(
        to writer: inout ByteWriter,
        surfaceID: UInt32,
        box: (top: Int32, left: Int32, bottom: Int32, right: Int32),
        clipRectangles: [(top: Int32, left: Int32, bottom: Int32, right: Int32)]?
    ) {
        writer.writeUInt32LE(surfaceID)
        writeRect(to: &writer, box)
        if let clipRectangles {
            writer.writeUInt8(1)
            writer.writeUInt32LE(UInt32(clipRectangles.count))
            for rectangle in clipRectangles {
                writeRect(to: &writer, rectangle)
            }
        } else {
            writer.writeUInt8(0)
        }
    }

    private func writeRect(
        to writer: inout ByteWriter,
        _ rectangle: (top: Int32, left: Int32, bottom: Int32, right: Int32)
    ) {
        writer.writeInt32LE(rectangle.top)
        writer.writeInt32LE(rectangle.left)
        writer.writeInt32LE(rectangle.bottom)
        writer.writeInt32LE(rectangle.right)
    }

    private func writeEmptyMask(to writer: inout ByteWriter) {
        writer.writeUInt8(0)
        writer.writeInt32LE(0)
        writer.writeInt32LE(0)
        writer.writeUInt32LE(0)
    }

    private func writeSurfaceImage(
        to writer: inout ByteWriter,
        descriptorID: UInt64,
        surfaceID: UInt32
    ) {
        writer.writeUInt64LE(descriptorID)
        writer.writeUInt8(104) // SPICE_IMAGE_TYPE_SURFACE
        writer.writeUInt8(0)
        writer.writeUInt32LE(1)
        writer.writeUInt32LE(1)
        writer.writeUInt32LE(surfaceID)
    }

    private func encodeMini<Message: SpiceGeneratedMessage>(_ message: Message) throws -> Data {
        let id = try #require(Message.messageID)
        var body = ByteWriter()
        try message.encode(to: &body)
        return encodeMini(id: id, body: body.data)
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }

    private func miniMessageID(_ framed: Data) throws -> UInt16 {
        var reader = try ByteReader(framed)
        return try reader.readUInt16LE()
    }

    private func pixel(_ snapshot: FrameSnapshot, x: Int, y: Int) -> [UInt8] {
        let offset = y * snapshot.bytesPerRow + x * 4
        return Array(snapshot.pixels[offset..<(offset + 4)])
    }

    private func frameChanged(surfaceID: UInt32, revision: UInt64) -> DisplayEvent {
        .frameChanged(SurfaceRevision(
            surfaceID: surfaceID,
            lifecycleGeneration: 1,
            revision: revision
        ))
    }
}

private actor GatedDisplayTransport: SpiceTransport {
    private var inbound: [Data]
    private let gateAfterReads: Int
    private var readCount = 0
    private var remainingReadsReleased = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateIsBlocking = false
    private var gateBlockingWaiters: [CheckedContinuation<Void, Never>] = []
    private var readCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var connected = false
    private var closed = false

    init(inbound: [Data], gateAfterReads: Int) {
        self.inbound = inbound
        self.gateAfterReads = gateAfterReads
    }

    func connect() throws(TransportError) {
        connected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard connected, !closed else { throw .connectionClosed }
        if readCount >= gateAfterReads, !remainingReadsReleased {
            gateIsBlocking = true
            for continuation in gateBlockingWaiters { continuation.resume() }
            gateBlockingWaiters.removeAll()
            await withCheckedContinuation { gateWaiters.append($0) }
            guard connected, !closed else { throw .connectionClosed }
        }
        guard !inbound.isEmpty else {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                throw .cancelled
            }
            throw .connectionClosed
        }
        let data = inbound.removeFirst()
        guard data.count >= minimum, data.count <= maximum else {
            throw .connectionFailed("invalid test read size")
        }
        readCount += 1
        let ready = readCountWaiters.filter { readCount >= $0.0 }
        readCountWaiters.removeAll { readCount >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        return data
    }

    func write(_ data: sending Data) throws(TransportError) {
        _ = data
        guard connected, !closed else { throw .connectionClosed }
    }

    func close() {
        closed = true
        connected = false
        for continuation in gateWaiters { continuation.resume() }
        gateWaiters.removeAll()
    }

    func releaseRemainingReads() {
        remainingReadsReleased = true
        gateIsBlocking = false
        for continuation in gateWaiters { continuation.resume() }
        gateWaiters.removeAll()
    }

    func waitUntilReadCount(_ target: Int) async {
        guard readCount < target else { return }
        await withCheckedContinuation { readCountWaiters.append((target, $0)) }
    }

    func readCountSnapshot() -> Int {
        readCount
    }

    func waitUntilGateIsBlocking() async {
        guard !gateIsBlocking else { return }
        await withCheckedContinuation { gateBlockingWaiters.append($0) }
    }
}

private actor RetirableDisplayTransport: SpiceTransport {
    private var inbound: [Data]
    private var connected = false
    private var blockedRead: CheckedContinuation<Void, Never>?
    private var blockedReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(inbound: [Data]) {
        self.inbound = inbound
    }

    func connect() throws(TransportError) {
        connected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard connected else { throw .connectionClosed }
        if !inbound.isEmpty {
            let data = inbound.removeFirst()
            guard data.count >= minimum, data.count <= maximum else {
                throw .connectionFailed("invalid test read size")
            }
            return data
        }
        for continuation in blockedReadWaiters { continuation.resume() }
        blockedReadWaiters.removeAll()
        await withCheckedContinuation { blockedRead = $0 }
        throw .connectionClosed
    }

    func write(_ data: sending Data) throws(TransportError) {
        _ = data
        guard connected else { throw .connectionClosed }
    }

    func close() {
        connected = false
        blockedRead?.resume()
        blockedRead = nil
    }

    func waitUntilReadIsBlocked() async {
        guard blockedRead == nil else { return }
        await withCheckedContinuation { blockedReadWaiters.append($0) }
    }

    func releaseBlockedRead() {
        blockedRead?.resume()
        blockedRead = nil
    }
}

private actor GatedPatternJPEGDecoder: SpiceImageDecoder {
    nonisolated let format = SpiceImageFormat.jpeg
    private(set) var payloads: [Data] = []
    private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var decodeCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        payloads.append(payload)
        if payloads.count == 1 {
            for continuation in firstStartedWaiters { continuation.resume() }
            firstStartedWaiters.removeAll()
            await withCheckedContinuation { firstRelease = $0 }
        }
        let ready = decodeCountWaiters.filter { payloads.count >= $0.0 }
        decodeCountWaiters.removeAll { payloads.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        return try await PatternJPEGDecoder().decode(
            descriptor: descriptor,
            payload: payload
        )
    }

    func waitUntilFirstDecodeStarts() async {
        guard payloads.isEmpty else { return }
        await withCheckedContinuation { firstStartedWaiters.append($0) }
    }

    func releaseFirstDecode() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func waitUntilDecodeCount(_ target: Int) async {
        guard payloads.count < target else { return }
        await withCheckedContinuation { decodeCountWaiters.append((target, $0)) }
    }
}

private actor CancellationAwareJPEGDecoder: SpiceImageDecoder {
    nonisolated let format = SpiceImageFormat.jpeg
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        _ = descriptor
        _ = payload
        started = true
        for continuation in startedWaiters { continuation.resume() }
        startedWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            wasCancelled = true
            for continuation in cancellationWaiters { continuation.resume() }
            cancellationWaiters.removeAll()
            throw .cancelled
        }
        throw .decodeFailed
    }

    func waitUntilDecodeStarts() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
}

private actor ReleaseFailingJPEGDecoder: SpiceImageDecoder {
    nonisolated let format = SpiceImageFormat.jpeg
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        _ = descriptor
        _ = payload
        started = true
        for continuation in startedWaiters { continuation.resume() }
        startedWaiters.removeAll()
        await withCheckedContinuation { release = $0 }
        throw .decodeFailed
    }

    func waitUntilDecodeStarts() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func releaseWithFailure() {
        release?.resume()
        release = nil
    }
}

private struct StubJPEGDecoder: SpiceImageDecoder {
    nonisolated let format = SpiceImageFormat.jpeg
    let result: Result<SpiceDecodedImage, SpiceCodecError>

    func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        try result.get()
    }
}

private struct StubAdvancedVideoDecoderFactory: SpiceAdvancedVideoDecoderFactory {
    let decoder: StubAdvancedVideoDecoder

    func makeDecoder(
        codec: SpiceAdvancedVideoCodec,
        width: Int,
        height: Int
    ) throws(SpiceCodecError) -> any SpiceAdvancedVideoDecoder {
        guard codec == .h264, width == 2, height == 2 else {
            throw .invalidDimensions(width: width, height: height)
        }
        return decoder
    }
}

private actor StubAdvancedVideoDecoder: SpiceAdvancedVideoDecoder {
    let image: SpiceDecodedImage
    private(set) var receivedPayloads: [Data] = []
    private(set) var closeCount = 0

    init(image: SpiceDecodedImage) {
        self.image = image
    }

    func decode(
        payload: Data,
        multimediaTime: UInt32
    ) async throws(SpiceCodecError) -> SpiceDecodedImage? {
        receivedPayloads.append(payload)
        return image
    }

    func close() async {
        closeCount += 1
    }

    func diagnosticsSnapshot() async -> SpiceAdvancedVideoDecoderDiagnostics {
        SpiceAdvancedVideoDecoderDiagnostics(
            decodedFrameCount: UInt64(receivedPayloads.count)
        )
    }
}

private struct PatternJPEGDecoder: SpiceImageDecoder {
    nonisolated let format = SpiceImageFormat.jpeg

    func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        guard let key = payload.first, key != 0xff else {
            throw .decodeFailed
        }
        let pixelCount = descriptor.width * descriptor.height
        var pixels = Data(capacity: pixelCount * 4)
        for pixelIndex in 0..<pixelCount {
            pixels.append((key - 1) * 40 + 10 + UInt8(pixelIndex) * 10)
            pixels.append(0)
            pixels.append(0)
            pixels.append(0)
        }
        return SpiceDecodedImage(
            width: descriptor.width,
            height: descriptor.height,
            bytesPerRow: descriptor.width * 4,
            pixelsBGRA: pixels
        )
    }
}

private actor CountingPatternJPEGDecoder: SpiceImageDecoder {
    nonisolated let format = SpiceImageFormat.jpeg
    private(set) var decodeCount = 0

    func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        decodeCount += 1
        return try await PatternJPEGDecoder().decode(descriptor: descriptor, payload: payload)
    }
}

private actor RecordingDisplayMultimediaClock: MultimediaClockScheduling {
    private var currentTime: UInt32
    private let forcedLateWaitTargets: Set<UInt32>
    private(set) var waitedTargets: [UInt32] = []

    init(initialTime: UInt32, forcedLateWaitTargets: Set<UInt32> = []) {
        currentTime = initialTime
        self.forcedLateWaitTargets = forcedLateWaitTargets
    }

    func reset(to multimediaTime: UInt32) {
        currentTime = multimediaTime
    }

    func synchronize(playbackTime: UInt32, delayMilliseconds: UInt32) {
        currentTime = playbackTime &- delayMilliseconds
    }

    func timing(for multimediaTime: UInt32) -> MultimediaFrameTiming {
        MultimediaTimestamp.timing(current: currentTime, target: multimediaTime)
    }

    func wait(until multimediaTime: UInt32) -> MultimediaFrameTiming {
        waitedTargets.append(multimediaTime)
        if forcedLateWaitTargets.contains(multimediaTime) {
            currentTime = multimediaTime &+ 1
            return .late(milliseconds: 1)
        }
        let result = timing(for: multimediaTime)
        if case .early = result {
            currentTime = multimediaTime
            return .due
        }
        return result
    }
}

private struct StubLZDecoder: SpiceImageDecoder {
    nonisolated let format = SpiceImageFormat.lzRGB
    let result: Result<SpiceDecodedImage, SpiceCodecError>

    func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        try result.get()
    }
}
