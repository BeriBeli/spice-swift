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
}

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
