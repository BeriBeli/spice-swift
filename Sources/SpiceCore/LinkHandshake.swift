import Foundation
import SpiceProtocol
import SpiceTransport
import SpiceWire

package struct LinkRequest: Sendable, Equatable {
    package var connectionID: UInt32
    package var channelType: UInt8
    package var channelID: UInt8
    package var commonCapabilities: [UInt32]
    package var channelCapabilities: [UInt32]

    package init(
        connectionID: UInt32,
        channelType: UInt8,
        channelID: UInt8,
        commonCapabilities: [UInt32],
        channelCapabilities: [UInt32] = []
    ) {
        self.connectionID = connectionID
        self.channelType = channelType
        self.channelID = channelID
        self.commonCapabilities = commonCapabilities
        self.channelCapabilities = channelCapabilities
    }

    package static func main(connectionID: UInt32 = 0) -> Self {
        channel(connectionID: connectionID, key: ChannelKey(type: 1, id: 0))
    }

    package static func migrationTargetMain(
        connectionID: UInt32 = 0,
        requestsSeamless: Bool
    ) -> Self {
        var request = main(connectionID: connectionID)
        var capabilities = CapabilitySet<MainCapability>()
        capabilities.insert(.agentConnectedTokens)
        capabilities.insert(.semiSeamlessMigrate)
        if requestsSeamless {
            capabilities.insert(.seamlessMigrate)
        }
        request.channelCapabilities = capabilities.wireWords
        return request
    }

    package static func channel(
        connectionID: UInt32,
        key: ChannelKey,
        advertisesH264: Bool = false,
        advertisesH265: Bool = false
    ) -> Self {
        var common = CapabilitySet<CommonCapability>()
        common.insert(.protocolAuthSelection)
        common.insert(.authSpice)
        common.insert(.miniHeader)
        var channelCapabilities: [UInt32] = []
        if key.type == 1 {
            var main = CapabilitySet<MainCapability>()
            main.insert(.agentConnectedTokens)
            main.insert(.semiSeamlessMigrate)
            main.insert(.seamlessMigrate)
            channelCapabilities = main.wireWords
        } else if key.type == 2 {
            var display = CapabilitySet<DisplayCapability>()
            display.insert(.sizedStream)
            display.insert(.monitorsConfig)
            display.insert(.multiCodec)
            display.insert(.codecMJPEG)
            if advertisesH264 {
                display.insert(.codecH264)
            }
            if advertisesH265 {
                display.insert(.codecH265)
            }
            channelCapabilities = display.wireWords
        } else if key.type == 5 {
            var playback = CapabilitySet<PlaybackCapability>()
            playback.insert(.volume)
            playback.insert(.latency)
            channelCapabilities = playback.wireWords
        }
        return Self(
            connectionID: connectionID,
            channelType: key.type,
            channelID: key.id,
            commonCapabilities: common.wireWords,
            channelCapabilities: channelCapabilities
        )
    }
}

package struct LinkHandshakeResult: Sendable, Equatable {
    package let headerMode: HeaderMode
    package let commonCapabilities: CapabilitySet<CommonCapability>
    package let channelCapabilityWords: [UInt32]
}

package struct LinkHandshake: Sendable {
    private let limits: WireLimits

    package init(limits: WireLimits = .init()) {
        self.limits = limits
    }

    package func perform(
        transport: any SpiceTransport,
        request: LinkRequest,
        password: consuming Data,
        ticketEncryptor: any TicketEncrypting
    ) async throws(ChannelError) -> LinkHandshakeResult {
        let outbound: Data
        do {
            outbound = try encode(request)
        } catch let error {
            throw .wire(error)
        }
        do {
            try await transport.write(outbound)
        } catch let error {
            throw .transport(error)
        }

        let headerData: Data
        do {
            headerData = try await transport.readExactly(SpiceLinkHeader.minimumWireSize)
        } catch let error {
            throw .transport(error)
        }

        let header: SpiceLinkHeader
        do {
            var reader = try ByteReader(headerData)
            header = try SpiceLinkHeader.decode(from: &reader)
            try reader.requireFullyConsumed()
            try header.validate()
        } catch let error {
            throw .wire(error)
        }

        guard let replySize = Int(exactly: header.size) else {
            throw .wire(.integerOverflow)
        }
        guard replySize >= SpiceLinkReply.minimumWireSize else {
            throw .wire(.invalidSize(replySize))
        }
        guard replySize <= limits.maximumMessageSize else {
            throw .wire(.messageTooLarge(actual: replySize, maximum: limits.maximumMessageSize))
        }

        let replyBody: Data
        do {
            replyBody = try await transport.readExactly(replySize)
        } catch let error {
            throw .transport(error)
        }

        let reply: SpiceLinkReply
        do {
            var reader = try ByteReader(replyBody)
            reply = try SpiceLinkReply.decode(from: &reader)
        } catch let error {
            throw .wire(error)
        }
        guard reply.error == 0 else {
            throw .linkRejected(code: reply.error)
        }

        let negotiated: LinkHandshakeResult
        do {
            negotiated = try parseCapabilities(reply: reply, body: replyBody)
        } catch let error {
            throw .wire(error)
        }

        if negotiated.commonCapabilities.contains(.protocolAuthSelection) {
            guard negotiated.commonCapabilities.contains(.authSpice) else {
                throw .authentication(.unsupportedMethod)
            }
            var writer = ByteWriter(capacity: SpiceLinkAuthMechanism.minimumWireSize)
            do {
                try SpiceLinkAuthMechanism(authenticationMechanism: 1).encode(to: &writer)
            } catch let error {
                throw .wire(error)
            }
            do {
                try await transport.write(writer.data)
            } catch let error {
                throw .transport(error)
            }
        }

        let encryptedTicket: Data
        do {
            encryptedTicket = try ticketEncryptor.encryptTicket(
                password: password,
                publicKeyDER: reply.publicKey
            )
        } catch let error {
            throw .authentication(error)
        }
        guard encryptedTicket.count == SpiceProtocolConstants.encryptedTicketByteCount else {
            throw .authentication(.encryptionFailed("ticket must be exactly 128 bytes"))
        }
        do {
            try await transport.write(encryptedTicket)
        } catch let error {
            throw .transport(error)
        }

        let resultData: Data
        do {
            resultData = try await transport.readExactly(SpiceLinkResult.minimumWireSize)
        } catch let error {
            throw .transport(error)
        }
        let result: SpiceLinkResult
        do {
            var reader = try ByteReader(resultData)
            result = try SpiceLinkResult.decode(from: &reader)
            try reader.requireFullyConsumed()
        } catch let error {
            throw .wire(error)
        }
        guard result.error == 0 else {
            throw .authentication(.rejected(code: result.error))
        }
        return negotiated
    }

    private func encode(_ request: LinkRequest) throws(WireError) -> Data {
        guard request.commonCapabilities.count <= Int(UInt32.max),
              request.channelCapabilities.count <= Int(UInt32.max)
        else {
            throw .integerOverflow
        }
        let (capabilityWordCount, countOverflow) = request.commonCapabilities.count
            .addingReportingOverflow(request.channelCapabilities.count)
        guard !countOverflow else {
            throw .integerOverflow
        }
        let (capabilityBytes, sizeOverflow) = capabilityWordCount
            .multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
        guard !sizeOverflow else {
            throw .integerOverflow
        }
        let (bodySize, bodyOverflow) = SpiceLinkMessage.minimumWireSize
            .addingReportingOverflow(capabilityBytes)
        guard !bodyOverflow, bodySize <= Int(UInt32.max) else {
            throw .integerOverflow
        }

        let message = SpiceLinkMessage(
            connectionID: request.connectionID,
            channelType: request.channelType,
            channelID: request.channelID,
            commonCapabilityWordCount: UInt32(request.commonCapabilities.count),
            channelCapabilityWordCount: UInt32(request.channelCapabilities.count),
            capabilitiesOffset: UInt32(SpiceLinkMessage.minimumWireSize)
        )
        let header = SpiceLinkHeader(
            magic: SpiceProtocolConstants.magic,
            majorVersion: SpiceProtocolConstants.majorVersion,
            minorVersion: SpiceProtocolConstants.minorVersion,
            size: UInt32(bodySize)
        )

        var writer = ByteWriter(capacity: SpiceLinkHeader.minimumWireSize + bodySize)
        try header.encode(to: &writer)
        try message.encode(to: &writer)
        for word in request.commonCapabilities {
            writer.writeUInt32LE(word)
        }
        for word in request.channelCapabilities {
            writer.writeUInt32LE(word)
        }
        return writer.data
    }

    private func parseCapabilities(
        reply: SpiceLinkReply,
        body: Data
    ) throws(WireError) -> LinkHandshakeResult {
        guard let commonCount = Int(exactly: reply.commonCapabilityWordCount),
              let channelCount = Int(exactly: reply.channelCapabilityWordCount)
        else {
            throw .integerOverflow
        }
        let (totalCount, countOverflow) = commonCount.addingReportingOverflow(channelCount)
        guard !countOverflow else {
            throw .integerOverflow
        }
        let (byteCount, byteOverflow) = totalCount.multipliedReportingOverflow(
            by: MemoryLayout<UInt32>.size
        )
        guard !byteOverflow else {
            throw .integerOverflow
        }
        let resolver = try SpiceAddressResolver(messageSize: body.count)
        let range = try resolver.resolve(UInt64(reply.capabilitiesOffset), minimumSize: byteCount)
        var reader = try ByteReader(body.subdata(in: range))
        var commonWords: [UInt32] = []
        commonWords.reserveCapacity(commonCount)
        for _ in 0..<commonCount {
            commonWords.append(try reader.readUInt32LE())
        }
        var channelWords: [UInt32] = []
        channelWords.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            channelWords.append(try reader.readUInt32LE())
        }
        try reader.requireFullyConsumed()

        let common = CapabilitySet<CommonCapability>(words: commonWords)
        return LinkHandshakeResult(
            headerMode: common.contains(.miniHeader) ? .mini : .full,
            commonCapabilities: common,
            channelCapabilityWords: channelWords
        )
    }
}
