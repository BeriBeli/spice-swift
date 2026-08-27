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
    package let bodySlice: WireSlice
    /// Compatibility boundary for existing subsystem and public event paths.
    /// Production protocol parsers should consume `bodySlice` instead.
    package var body: Data { bodySlice.data }
    package var ownedBody: WireSlice { bodySlice }
    /// Bytes retained by `body`'s physical-message backing storage.
    ///
    /// A logical submessage may have a small body while its `Data` slice keeps
    /// the entire physical SPICE message alive. Callers that suspend while
    /// retaining the body must account this value rather than `body.count`.
    package let retainedBodyByteCount: Int
    /// The number of physical messages represented by this dispatched logical
    /// message. This is one only for the final logical message in a batch.
    package let acknowledgmentCount: Int

    package init(
        serial: UInt64?,
        type: UInt16,
        subListOffset: UInt32?,
        body: Data,
        retainedBodyByteCount: Int? = nil,
        acknowledgmentCount: Int = 1
    ) {
        self.init(
            serial: serial,
            type: type,
            subListOffset: subListOffset,
            bodySlice: OwnedBytes(body).wholeSlice,
            retainedBodyByteCount: retainedBodyByteCount,
            acknowledgmentCount: acknowledgmentCount
        )
    }

    package init(
        serial: UInt64?,
        type: UInt16,
        subListOffset: UInt32?,
        bodySlice: WireSlice,
        retainedBodyByteCount: Int? = nil,
        acknowledgmentCount: Int = 1
    ) {
        self.serial = serial
        self.type = type
        self.subListOffset = subListOffset
        self.bodySlice = bodySlice
        self.retainedBodyByteCount = max(
            bodySlice.count,
            retainedBodyByteCount ?? bodySlice.retainedOwnerByteCount
        )
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
    package let storageSlice: WireSlice
    package let messages: [FramedMessageSlice]

    package var storage: Data { storageSlice.data }
    package var physicalBodySize: Int { storageSlice.count }
    package var logicalMessages: [FramedMessageSlice] { messages }
    package var acknowledgmentCount: Int { 1 }

    package func body(for message: FramedMessageSlice) -> Data {
        bodySlice(for: message).data
    }

    package func bodySlice(for message: FramedMessageSlice) -> WireSlice {
        precondition(
            message.bodyRange.lowerBound >= 0
                && message.bodyRange.upperBound <= storageSlice.count,
            "logical message slice does not belong to this physical message"
        )
        return try! storageSlice.slice(message.bodyRange)
    }

    package func framedMessage(at index: Int) -> FramedMessage {
        let message = messages[index]
        return FramedMessage(
            serial: serial,
            type: message.type,
            subListOffset: nil,
            bodySlice: bodySlice(for: message),
            retainedBodyByteCount: storageSlice.retainedOwnerByteCount,
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
        storageSlice = framedMessage.bodySlice

        guard let subListValue = framedMessage.subListOffset else {
            messages = [
                FramedMessageSlice(
                    type: framedMessage.type,
                    bodyRange: 0..<framedMessage.bodySlice.count
                )
            ]
            return
        }

        let hasSubmessageList = physicalType == Self.messageListType || subListValue != 0
        guard hasSubmessageList else {
            messages = [
                FramedMessageSlice(
                    type: framedMessage.type,
                    bodyRange: 0..<framedMessage.bodySlice.count
                )
            ]
            return
        }

        guard let listOffset = Int(exactly: subListValue), listOffset <= storageSlice.count else {
            throw .invalidOffset(UInt64(subListValue))
        }
        let countEnd = try Self.checkedEnd(start: listOffset, length: 2)
        guard countEnd <= storageSlice.count else {
            throw .truncated(expected: 2, remaining: max(storageSlice.count - listOffset, 0))
        }
        let count = Int(try Self.readUInt16LE(storageSlice, at: listOffset))
        guard count <= maximumSubmessages else {
            throw .messageTooLarge(actual: count, maximum: maximumSubmessages)
        }
        let (offsetTableSize, tableSizeOverflow) = count.multipliedReportingOverflow(by: 4)
        guard !tableSizeOverflow else {
            throw .integerOverflow
        }
        let metadataEnd = try Self.checkedEnd(start: countEnd, length: offsetTableSize)
        guard metadataEnd <= storageSlice.count else {
            throw .truncated(
                expected: offsetTableSize,
                remaining: max(storageSlice.count - countEnd, 0)
            )
        }

        var parsed: [(type: UInt16, bodyRange: Range<Int>, completeRange: Range<Int>)] = []
        parsed.reserveCapacity(count)
        var completeRanges: [Range<Int>] = []
        completeRanges.reserveCapacity(count)

        for index in 0..<count {
            let tableEntry = try Self.checkedEnd(start: countEnd, length: index * 4)
            let rawOffset = try Self.readUInt32LE(storageSlice, at: tableEntry)
            guard let submessageOffset = Int(exactly: rawOffset) else {
                throw .integerOverflow
            }

            // A submessage must not reference the main payload or any byte of
            // the list metadata. This also rejects duplicate metadata offsets.
            guard submessageOffset >= metadataEnd else {
                throw .invalidOffset(UInt64(rawOffset))
            }
            let headerEnd = try Self.checkedEnd(start: submessageOffset, length: 6)
            guard headerEnd <= storageSlice.count else {
                throw .truncated(
                    expected: 6,
                    remaining: max(storageSlice.count - submessageOffset, 0)
                )
            }
            let type = try Self.readUInt16LE(storageSlice, at: submessageOffset)
            let rawSize = try Self.readUInt32LE(storageSlice, at: submessageOffset + 2)
            guard let size = Int(exactly: rawSize) else {
                throw .integerOverflow
            }
            let messageEnd = try Self.checkedEnd(start: headerEnd, length: size)
            guard messageEnd <= storageSlice.count else {
                throw .truncated(
                    expected: size,
                    remaining: max(storageSlice.count - headerEnd, 0)
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

    private static func readUInt16LE(
        _ bytes: WireSlice,
        at offset: Int
    ) throws(WireError) -> UInt16 {
        let (end, overflow) = offset.addingReportingOverflow(2)
        guard offset >= 0, !overflow, end <= bytes.count else {
            throw .truncated(expected: 2, remaining: max(bytes.count - offset, 0))
        }
        return bytes.withSpan { span in
            UInt16(span[offset]) | UInt16(span[offset + 1]) << 8
        }
    }

    private static func readUInt32LE(
        _ bytes: WireSlice,
        at offset: Int
    ) throws(WireError) -> UInt32 {
        let (end, overflow) = offset.addingReportingOverflow(4)
        guard offset >= 0, !overflow, end <= bytes.count else {
            throw .truncated(expected: 4, remaining: max(bytes.count - offset, 0))
        }
        return bytes.withSpan { span in
            UInt32(span[offset])
                | UInt32(span[offset + 1]) << 8
                | UInt32(span[offset + 2]) << 16
                | UInt32(span[offset + 3]) << 24
        }
    }
}

package typealias InboundMessageBatch = FramedMessageBatch
package typealias InboundLogicalMessage = FramedMessageSlice

package struct MessageFramerDiagnostics: Sendable, Equatable {
    package let bodyCoalesces: UInt64
    package let bodyCopyBytes: UInt64
    package let queueCompactionBytes: UInt64
    package let retainedOwnerCount: Int
    package let retainedOwnerBytes: Int
    package let bufferedSegmentCount: Int
}

package struct MessageFramer: Sendable {
    private struct QueuePosition: Sendable {
        let segmentIndex: Int
        let offset: Int
    }

    private struct PeekedMessage: Sendable {
        let message: FramedMessage
        let wireByteCount: Int
    }

    package let mode: HeaderMode
    package let limits: WireLimits

    // Fully consumed slots are cleared immediately so advancing `headIndex`
    // cannot invisibly retain old receive owners. Prefix removal below only
    // moves optional owner references; it never compacts received bytes.
    private var segments: [OwnedBytes?] = []
    private var headIndex = 0
    private var headOffset = 0
    private var bufferedBytes = 0
    private var peekedMessage: PeekedMessage?
    private var bodyCoalesces: UInt64 = 0
    private var bodyCopyBytes: UInt64 = 0

    package init(mode: HeaderMode, limits: WireLimits = .init()) {
        self.mode = mode
        self.limits = limits
    }

    package var bufferedByteCount: Int { bufferedBytes }

    package var diagnostics: MessageFramerDiagnostics {
        var retainedBytes = 0
        var retainedOwnerIDs: Set<ObjectIdentifier> = []
        var bufferedSegmentCount = 0
        for owner in segments {
            guard let owner else { continue }
            bufferedSegmentCount += 1
            guard retainedOwnerIDs.insert(
                ObjectIdentifier(owner.ownerLifetimeToken)
            ).inserted else {
                continue
            }
            let (next, overflow) = retainedBytes.addingReportingOverflow(owner.count)
            retainedBytes = overflow ? Int.max : next
        }
        if let peekedMessage {
            let cachedBody = peekedMessage.message.bodySlice
            if retainedOwnerIDs.insert(
                ObjectIdentifier(cachedBody.owner.ownerLifetimeToken)
            ).inserted {
                let (next, overflow) = retainedBytes.addingReportingOverflow(
                    cachedBody.retainedOwnerByteCount
                )
                retainedBytes = overflow ? Int.max : next
            }
        }
        return MessageFramerDiagnostics(
            bodyCoalesces: bodyCoalesces,
            bodyCopyBytes: bodyCopyBytes,
            queueCompactionBytes: 0,
            retainedOwnerCount: retainedOwnerIDs.count,
            retainedOwnerBytes: retainedBytes,
            bufferedSegmentCount: bufferedSegmentCount
        )
    }

    package mutating func append(_ bytes: Data) throws(WireError) {
        try append(OwnedBytes(bytes))
    }

    package mutating func append(_ bytes: OwnedBytes) throws(WireError) {
        let (newCount, overflow) = bufferedBytes.addingReportingOverflow(bytes.count)
        guard !overflow else {
            throw .integerOverflow
        }
        guard newCount <= limits.maximumBufferedBytes else {
            throw .messageTooLarge(actual: newCount, maximum: limits.maximumBufferedBytes)
        }
        guard !bytes.isEmpty else { return }
        segments.append(bytes)
        bufferedBytes = newCount
    }

    package mutating func nextMessage() throws(WireError) -> FramedMessage? {
        guard let peeked = try peekMessage() else {
            return nil
        }
        consume(peeked.wireByteCount)
        return peeked.message
    }

    package mutating func nextBatch(
        maximumSubmessages: Int = FramedMessageBatch.defaultMaximumSubmessages
    ) throws(WireError) -> FramedMessageBatch? {
        guard let peeked = try peekMessage() else {
            return nil
        }
        // Parsing is part of the physical-boundary transaction. A malformed
        // submessage list leaves the queue and cached coalesced owner intact,
        // so retrying observes the same typed error without copying again.
        let batch = try peeked.message.messageBatch(
            maximumSubmessages: maximumSubmessages
        )
        consume(peeked.wireByteCount)
        return batch
    }

    /// Discards the unread boundary and releases every receive/coalesced
    /// owner. Copy counters remain cumulative diagnostics for this framer.
    package mutating func reset() {
        segments.removeAll(keepingCapacity: true)
        headIndex = 0
        headOffset = 0
        bufferedBytes = 0
        peekedMessage = nil
    }

    private mutating func peekMessage() throws(WireError) -> PeekedMessage? {
        if let peekedMessage {
            return peekedMessage
        }
        guard bufferedBytes >= mode.wireSize else {
            return nil
        }

        var headerOffset = 0
        let serial: UInt64?
        let type: UInt16
        let bodySizeValue: UInt32
        let subListOffset: UInt32?
        switch mode {
        case .full:
            serial = try peekUInt64LE(offset: &headerOffset)
            type = try peekUInt16LE(offset: &headerOffset)
            bodySizeValue = try peekUInt32LE(offset: &headerOffset)
            subListOffset = try peekUInt32LE(offset: &headerOffset)
        case .mini:
            serial = nil
            type = try peekUInt16LE(offset: &headerOffset)
            bodySizeValue = try peekUInt32LE(offset: &headerOffset)
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
        let (messageSize, messageSizeOverflow) = mode.wireSize.addingReportingOverflow(
            bodySize
        )
        guard !messageSizeOverflow else {
            throw .integerOverflow
        }
        guard bufferedBytes >= messageSize else {
            return nil
        }

        let bodySlice = try makeBodySlice(
            relativeOffset: mode.wireSize,
            count: bodySize
        )
        let peeked = PeekedMessage(
            message: FramedMessage(
                serial: serial,
                type: type,
                subListOffset: subListOffset,
                bodySlice: bodySlice
            ),
            wireByteCount: messageSize
        )
        peekedMessage = peeked
        return peeked
    }

    private func peekUInt16LE(offset: inout Int) throws(WireError) -> UInt16 {
        var value: UInt16 = 0
        for index in 0..<2 {
            value |= UInt16(try byte(at: offset + index)) << UInt16(index * 8)
        }
        offset += 2
        return value
    }

    private func peekUInt32LE(offset: inout Int) throws(WireError) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(try byte(at: offset + index)) << UInt32(index * 8)
        }
        offset += 4
        return value
    }

    private func peekUInt64LE(offset: inout Int) throws(WireError) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(try byte(at: offset + index)) << UInt64(index * 8)
        }
        offset += 8
        return value
    }

    private func byte(at relativeOffset: Int) throws(WireError) -> UInt8 {
        guard relativeOffset >= 0, relativeOffset < bufferedBytes,
              var position = position(at: relativeOffset)
        else {
            throw .truncated(expected: 1, remaining: max(bufferedBytes - relativeOffset, 0))
        }
        if position.offset == owner(at: position.segmentIndex).count {
            position = QueuePosition(segmentIndex: position.segmentIndex + 1, offset: 0)
        }
        return owner(at: position.segmentIndex).withSpan { $0[position.offset] }
    }

    private mutating func makeBodySlice(
        relativeOffset: Int,
        count: Int
    ) throws(WireError) -> WireSlice {
        guard var start = position(at: relativeOffset) else {
            throw .truncated(expected: count, remaining: 0)
        }
        if count > 0,
           start.offset == owner(at: start.segmentIndex).count,
           start.segmentIndex + 1 < segments.count
        {
            start = QueuePosition(segmentIndex: start.segmentIndex + 1, offset: 0)
        }
        let firstOwner = owner(at: start.segmentIndex)
        let available = firstOwner.count - start.offset
        if count <= available {
            return try firstOwner.slice(start.offset..<(start.offset + count))
        }

        var coalesced = Data(count: count)
        coalesced.withUnsafeMutableBytes { destination in
            var destinationOffset = 0
            var segmentIndex = start.segmentIndex
            var segmentOffset = start.offset
            while destinationOffset < count {
                let owner = owner(at: segmentIndex)
                let copiedCount = min(owner.count - segmentOffset, count - destinationOffset)
                owner.withSpan { source in
                    for index in 0..<copiedCount {
                        destination[destinationOffset + index] = source[segmentOffset + index]
                    }
                }
                destinationOffset += copiedCount
                segmentIndex += 1
                segmentOffset = 0
            }
        }
        Self.saturatingAdd(1, to: &bodyCoalesces)
        Self.saturatingAdd(UInt64(count), to: &bodyCopyBytes)
        return OwnedBytes(coalesced).wholeSlice
    }

    /// Finds a boundary relative to the unread head. When the boundary is the
    /// end of a segment, that segment is preferred so an empty body can still
    /// share its physical input owner.
    private func position(at relativeOffset: Int) -> QueuePosition? {
        guard relativeOffset >= 0, relativeOffset <= bufferedBytes,
              headIndex < segments.count
        else {
            return nil
        }
        var remaining = relativeOffset
        var index = headIndex
        var offset = headOffset
        while index < segments.count {
            let available = owner(at: index).count - offset
            if remaining <= available {
                return QueuePosition(segmentIndex: index, offset: offset + remaining)
            }
            remaining -= available
            index += 1
            offset = 0
        }
        return nil
    }

    private mutating func consume(_ count: Int) {
        precondition(count >= 0 && count <= bufferedBytes)
        var remaining = count
        while remaining > 0 {
            let available = owner(at: headIndex).count - headOffset
            if remaining < available {
                headOffset += remaining
                remaining = 0
            } else {
                remaining -= available
                segments[headIndex] = nil
                headIndex += 1
                headOffset = 0
            }
        }
        bufferedBytes -= count
        peekedMessage = nil

        if bufferedBytes == 0 {
            reset()
        } else if headIndex >= 1_024, headIndex >= segments.count / 2 {
            // This moves only small owner references; no received byte is
            // compacted or copied.
            segments.removeFirst(headIndex)
            headIndex = 0
        }
    }

    private func owner(at index: Int) -> OwnedBytes {
        guard let owner = segments[index] else {
            preconditionFailure("message framer accessed a consumed segment")
        }
        return owner
    }

    private static func saturatingAdd(_ addition: UInt64, to value: inout UInt64) {
        let (sum, overflow) = value.addingReportingOverflow(addition)
        value = overflow ? UInt64.max : sum
    }
}
