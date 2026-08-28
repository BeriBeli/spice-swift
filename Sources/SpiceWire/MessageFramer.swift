import Foundation

package enum HeaderMode: Sendable, Equatable {
    case full
    case mini

    package var wireSize: Int {
        switch self {
        case .full: 18
        case .mini: 6
        }
    }
}

package struct FramedMessage: Sendable, Equatable {
    package let serial: UInt64?
    package let type: UInt16
    package let subListOffset: UInt32?
    package let body: Data
    /// The number of physical messages represented by this dispatched logical
    /// message. This is one only for the final logical message in a batch.
    package let acknowledgmentCount: Int

    package init(
        serial: UInt64?,
        type: UInt16,
        subListOffset: UInt32?,
        body: Data,
        acknowledgmentCount: Int = 1
    ) {
        self.serial = serial
        self.type = type
        self.subListOffset = subListOffset
        self.body = body
        self.acknowledgmentCount = acknowledgmentCount
    }

    package func messageBatch(
        maximumSubmessages: Int = FramedMessageBatch.defaultMaximumSubmessages
    ) throws(WireError) -> FramedMessageBatch {
        try FramedMessageBatch(
            framedMessage: self,
            maximumSubmessages: maximumSubmessages
        )
    }
}

/// A logical message contained by one physical SPICE wire message.
///
/// The slice intentionally stores only a range. `FramedMessageBatch.storage`
/// owns the bytes once for the entire physical message.
package struct FramedMessageSlice: Sendable, Equatable {
    package let type: UInt16
    package let bodyRange: Range<Int>
    package let index: Int
    package let isLastInPhysicalMessage: Bool

    package init(
        type: UInt16,
        bodyRange: Range<Int>,
        index: Int = 0,
        isLastInPhysicalMessage: Bool = true
    ) {
        self.type = type
        self.bodyRange = bodyRange
        self.index = index
        self.isLastInPhysicalMessage = isLastInPhysicalMessage
    }
}

/// One physical message and all logical messages it contains.
///
/// A batch is exactly one ACK and serial-ordering unit, including an empty
/// `SPICE_MSG_LIST`. Logical slices execute in array order.
package struct FramedMessageBatch: Sendable, Equatable {
    package static let defaultMaximumSubmessages = 4_096
    package static let messageListType: UInt16 = 8

    package let serial: UInt64?
    package let physicalType: UInt16
    package let storage: Data
    package let messages: [FramedMessageSlice]

    package var physicalBodySize: Int { storage.count }
    package var logicalMessages: [FramedMessageSlice] { messages }
    package var acknowledgmentCount: Int { 1 }

    package func body(for message: FramedMessageSlice) -> Data {
        precondition(
            message.bodyRange.lowerBound >= 0
                && message.bodyRange.upperBound <= storage.count,
            "logical message slice does not belong to this physical message"
        )
        let lower = storage.startIndex + message.bodyRange.lowerBound
        let upper = storage.startIndex + message.bodyRange.upperBound
        return storage[lower..<upper]
    }

    package func framedMessage(at index: Int) -> FramedMessage {
        let message = messages[index]
        return FramedMessage(
            serial: serial,
            type: message.type,
            subListOffset: nil,
            body: body(for: message),
            acknowledgmentCount: message.isLastInPhysicalMessage ? 1 : 0
        )
    }

    fileprivate init(
        framedMessage: FramedMessage,
        maximumSubmessages: Int
    ) throws(WireError) {
        guard maximumSubmessages >= 0 else {
            throw .invalidSize(maximumSubmessages)
        }
        guard maximumSubmessages <= Self.defaultMaximumSubmessages else {
            throw .messageTooLarge(
                actual: maximumSubmessages,
                maximum: Self.defaultMaximumSubmessages
            )
        }

        serial = framedMessage.serial
        physicalType = framedMessage.type
        storage = framedMessage.body

        guard let subListValue = framedMessage.subListOffset else {
            messages = [
                FramedMessageSlice(
                    type: framedMessage.type,
                    bodyRange: 0..<framedMessage.body.count
                )
            ]
            return
        }

        let hasSubmessageList = physicalType == Self.messageListType || subListValue != 0
        guard hasSubmessageList else {
            messages = [
                FramedMessageSlice(
                    type: framedMessage.type,
                    bodyRange: 0..<framedMessage.body.count
                )
            ]
            return
        }

        guard let listOffset = Int(exactly: subListValue), listOffset <= storage.count else {
            throw .invalidOffset(UInt64(subListValue))
        }
        let countEnd = try Self.checkedEnd(start: listOffset, length: 2)
        guard countEnd <= storage.count else {
            throw .truncated(expected: 2, remaining: max(storage.count - listOffset, 0))
        }
        let count = Int(Self.readUInt16LE(storage, at: listOffset))
        guard count <= maximumSubmessages else {
            throw .messageTooLarge(actual: count, maximum: maximumSubmessages)
        }
        let (offsetTableSize, tableSizeOverflow) = count.multipliedReportingOverflow(by: 4)
        guard !tableSizeOverflow else {
            throw .integerOverflow
        }
        let metadataEnd = try Self.checkedEnd(start: countEnd, length: offsetTableSize)
        guard metadataEnd <= storage.count else {
            throw .truncated(
                expected: offsetTableSize,
                remaining: max(storage.count - countEnd, 0)
            )
        }

        var parsed: [(type: UInt16, bodyRange: Range<Int>, completeRange: Range<Int>)] = []
        parsed.reserveCapacity(count)
        var completeRanges: [Range<Int>] = []
        completeRanges.reserveCapacity(count)

        for index in 0..<count {
            let tableEntry = try Self.checkedEnd(start: countEnd, length: index * 4)
            let rawOffset = Self.readUInt32LE(storage, at: tableEntry)
            guard let submessageOffset = Int(exactly: rawOffset) else {
                throw .integerOverflow
            }

            // A submessage must not reference the main payload or any byte of
            // the list metadata. This also rejects duplicate metadata offsets.
            guard submessageOffset >= metadataEnd else {
                throw .invalidOffset(UInt64(rawOffset))
            }
            let headerEnd = try Self.checkedEnd(start: submessageOffset, length: 6)
            guard headerEnd <= storage.count else {
                throw .truncated(
                    expected: 6,
                    remaining: max(storage.count - submessageOffset, 0)
                )
            }
            let type = Self.readUInt16LE(storage, at: submessageOffset)
            let rawSize = Self.readUInt32LE(storage, at: submessageOffset + 2)
            guard let size = Int(exactly: rawSize) else {
                throw .integerOverflow
            }
            let messageEnd = try Self.checkedEnd(start: headerEnd, length: size)
            guard messageEnd <= storage.count else {
                throw .truncated(
                    expected: size,
                    remaining: max(storage.count - headerEnd, 0)
                )
            }
            let completeRange = submessageOffset..<messageEnd
            parsed.append((type, headerEnd..<messageEnd, completeRange))
            completeRanges.append(completeRange)
        }

        completeRanges.sort { lhs, rhs in
            lhs.lowerBound == rhs.lowerBound
                ? lhs.upperBound < rhs.upperBound
                : lhs.lowerBound < rhs.lowerBound
        }
        for pair in zip(completeRanges, completeRanges.dropFirst()) {
            guard pair.0.upperBound <= pair.1.lowerBound else {
                throw .invalidOffset(UInt64(pair.1.lowerBound))
            }
        }

        var ordered = parsed.map { ($0.type, $0.bodyRange) }
        if physicalType != Self.messageListType {
            ordered.append((physicalType, 0..<listOffset))
        }
        messages = ordered.enumerated().map { index, message in
            FramedMessageSlice(
                type: message.0,
                bodyRange: message.1,
                index: index,
                isLastInPhysicalMessage: index == ordered.count - 1
            )
        }
    }

    private static func checkedEnd(start: Int, length: Int) throws(WireError) -> Int {
        let (end, overflow) = start.addingReportingOverflow(length)
        guard !overflow else {
            throw .integerOverflow
        }
        return end
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes {
            UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}

package typealias InboundMessageBatch = FramedMessageBatch
package typealias InboundLogicalMessage = FramedMessageSlice

package struct MessageFramer: Sendable {
    package let mode: HeaderMode
    package let limits: WireLimits

    private var storage = Data()
    private var readOffset = 0

    package init(mode: HeaderMode, limits: WireLimits = .init()) {
        self.mode = mode
        self.limits = limits
    }

    package var bufferedByteCount: Int {
        storage.count - readOffset
    }

    package mutating func append(_ bytes: Data) throws(WireError) {
        let (newCount, overflow) = bufferedByteCount.addingReportingOverflow(bytes.count)
        guard !overflow else {
            throw .integerOverflow
        }
        guard newCount <= limits.maximumBufferedBytes else {
            throw .messageTooLarge(actual: newCount, maximum: limits.maximumBufferedBytes)
        }
        storage.append(bytes)
    }

    package mutating func nextMessage() throws(WireError) -> FramedMessage? {
        guard bufferedByteCount >= mode.wireSize else {
            return nil
        }

        let headerData = storage.subdata(in: readOffset..<(readOffset + mode.wireSize))
        var reader = try ByteReader(headerData)

        let serial: UInt64?
        let type: UInt16
        let bodySizeValue: UInt32
        let subListOffset: UInt32?

        switch mode {
        case .full:
            serial = try reader.readUInt64LE()
            type = try reader.readUInt16LE()
            bodySizeValue = try reader.readUInt32LE()
            subListOffset = try reader.readUInt32LE()
        case .mini:
            serial = nil
            type = try reader.readUInt16LE()
            bodySizeValue = try reader.readUInt32LE()
            subListOffset = nil
        }

        guard let bodySize = Int(exactly: bodySizeValue) else {
            throw .integerOverflow
        }
        guard bodySize <= limits.maximumMessageSize else {
            throw .messageTooLarge(actual: bodySize, maximum: limits.maximumMessageSize)
        }
        if let subListOffset, subListOffset != 0, subListOffset > bodySizeValue {
            throw .invalidOffset(UInt64(subListOffset))
        }

        let (messageSize, overflow) = mode.wireSize.addingReportingOverflow(bodySize)
        guard !overflow else {
            throw .integerOverflow
        }
        guard bufferedByteCount >= messageSize else {
            return nil
        }

        let bodyStart = readOffset + mode.wireSize
        let body = storage.subdata(in: bodyStart..<(bodyStart + bodySize))
        readOffset += messageSize
        compactIfNeeded()

        return FramedMessage(
            serial: serial,
            type: type,
            subListOffset: subListOffset,
            body: body
        )
    }

    package mutating func nextBatch(
        maximumSubmessages: Int = FramedMessageBatch.defaultMaximumSubmessages
    ) throws(WireError) -> FramedMessageBatch? {
        guard let message = try nextMessage() else {
            return nil
        }
        return try message.messageBatch(maximumSubmessages: maximumSubmessages)
    }

    private mutating func compactIfNeeded() {
        guard readOffset > 0 else {
            return
        }
        if readOffset == storage.count {
            storage.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 64 * 1024, readOffset >= storage.count / 2 {
            storage.removeSubrange(0..<readOffset)
            readOffset = 0
        }
    }
}
