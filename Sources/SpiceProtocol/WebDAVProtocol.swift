import Foundation
import SpiceWire

package enum SpicePortWire {
    package static let serverInit: UInt16 = 201
    package static let serverEvent: UInt16 = 202
    package static let clientEvent: UInt16 = 201
}

package enum SpicePortEvent: UInt8, Sendable, Equatable {
    case opened = 0
    case closed = 1
    case `break` = 2
}

package struct SpicePortInitialization: Sendable, Equatable {
    package let name: String
    package let opened: Bool
}

package struct SpicePortWireCodec: Sendable {
    private let maximumNameBytes: Int

    package init(maximumNameBytes: Int = 4_096) {
        self.maximumNameBytes = maximumNameBytes
    }

    package func decodeInitialization(_ body: Data) throws(WireError) -> SpicePortInitialization {
        var reader = try ByteReader(body)
        let rawSize = try reader.readUInt32LE()
        guard let size = Int(exactly: rawSize) else { throw .integerOverflow }
        guard size >= 2, size <= maximumNameBytes else {
            throw size > maximumNameBytes
                ? .messageTooLarge(actual: size, maximum: maximumNameBytes)
                : .invalidSize(size)
        }
        let bytes = try reader.readBytes(count: size)
        guard bytes.last == 0,
              !bytes.dropLast().contains(0),
              let name = String(data: bytes.dropLast(), encoding: .utf8),
              !name.isEmpty else {
            throw .unsupportedFeature("invalid SPICE port name")
        }
        let rawOpened = try reader.readUInt8()
        guard rawOpened <= 1 else {
            throw .invalidEnum(type: "SpicePortOpened", value: UInt64(rawOpened))
        }
        try reader.requireFullyConsumed()
        return SpicePortInitialization(name: name, opened: rawOpened == 1)
    }

    package func decodeEvent(_ body: Data) throws(WireError) -> SpicePortEvent {
        var reader = try ByteReader(body)
        let raw = try reader.readUInt8()
        guard let event = SpicePortEvent(rawValue: raw) else {
            throw .invalidEnum(type: "SpicePortEvent", value: UInt64(raw))
        }
        try reader.requireFullyConsumed()
        return event
    }

    package func encodeEvent(_ event: SpicePortEvent) -> Data {
        Data([event.rawValue])
    }
}

package struct SpiceWebDAVFrame: Sendable, Equatable {
    package let clientID: Int64
    package let data: Data

    package var closesClient: Bool { data.isEmpty }
}

package struct SpiceWebDAVMuxLimits: Sendable, Equatable {
    package var maximumFrameBytes: Int
    package var maximumBufferedBytes: Int

    package init(
        maximumFrameBytes: Int = Int(UInt16.max),
        maximumBufferedBytes: Int = 1 * 1_024 * 1_024
    ) {
        self.maximumFrameBytes = min(Int(UInt16.max), maximumFrameBytes)
        self.maximumBufferedBytes = maximumBufferedBytes
    }
}

package struct SpiceWebDAVMuxDecoder: Sendable {
    private let limits: SpiceWebDAVMuxLimits
    private var buffer = Data()

    package init(limits: SpiceWebDAVMuxLimits = .init()) {
        self.limits = limits
    }

    package mutating func append(_ data: Data) throws(WireError) -> [SpiceWebDAVFrame] {
        guard !data.isEmpty else { throw .invalidSize(0) }
        guard data.count <= limits.maximumBufferedBytes - buffer.count else {
            throw .messageTooLarge(
                actual: buffer.count + data.count,
                maximum: limits.maximumBufferedBytes
            )
        }
        buffer.append(data)
        var frames: [SpiceWebDAVFrame] = []
        var consumed = 0
        while buffer.count - consumed >= 10 {
            var reader = try ByteReader(buffer, offset: consumed)
            let clientID = Int64(bitPattern: try reader.readUInt64LE())
            let size = Int(try reader.readUInt16LE())
            guard size <= limits.maximumFrameBytes else {
                throw .messageTooLarge(actual: size, maximum: limits.maximumFrameBytes)
            }
            guard reader.remainingCount >= size else { break }
            frames.append(SpiceWebDAVFrame(
                clientID: clientID,
                data: try reader.readBytes(count: size)
            ))
            consumed += 10 + size
        }
        if consumed > 0 {
            buffer.removeFirst(consumed)
        }
        return frames
    }
}

package struct SpiceWebDAVMuxEncoder: Sendable {
    private let limits: SpiceWebDAVMuxLimits

    package init(limits: SpiceWebDAVMuxLimits = .init()) {
        self.limits = limits
    }

    package func encode(clientID: Int64, data: Data) throws(WireError) -> Data {
        guard data.count <= limits.maximumFrameBytes,
              let size = UInt16(exactly: data.count) else {
            throw .messageTooLarge(actual: data.count, maximum: limits.maximumFrameBytes)
        }
        var writer = ByteWriter(capacity: 10 + data.count)
        writer.writeUInt64LE(UInt64(bitPattern: clientID))
        writer.writeUInt16LE(size)
        writer.writeBytes(data)
        return writer.data
    }
}
