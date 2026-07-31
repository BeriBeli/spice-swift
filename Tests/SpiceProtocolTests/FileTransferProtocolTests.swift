import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("VDAgent file-transfer wire protocol")
struct FileTransferProtocolTests {
    @Test func encodesStartDataAndCancellationExactly() throws {
        let codec = VDAgentFileTransferCodec()
        let start = try codec.encodeStart(id: 7, name: "报告.txt", size: 5)
        #expect(start.type == VDAgentMessageType.fileTransferStart.rawValue)
        #expect(start.data.prefix(4) == uint32(7))
        #expect(start.data.dropFirst(4) == Data(
            "[vdagent-file-xfer]\nname=报告.txt\nsize=5\n\0".utf8
        ))

        let data = try codec.encodeData(id: 7, data: Data([1, 2, 3]))
        #expect(data.data == uint32(7) + uint64(3) + Data([1, 2, 3]))
        #expect(try codec.decode(data) == .data(id: 7, Data([1, 2, 3])))

        let cancel = codec.encodeStatus(id: 7, result: .cancelled)
        #expect(cancel.data == uint32(7) + uint32(1))
    }

    @Test func decodesEveryStatusAndDetailedErrorsStrictly() throws {
        let codec = VDAgentFileTransferCodec()
        for result in VDAgentFileTransferResult.allCasesForTesting {
            let message = status(id: 9, result: result)
            #expect(try codec.decode(message) == .status(VDAgentFileTransferStatus(
                id: 9,
                result: result,
                detail: nil
            )))
        }

        #expect(try codec.decode(status(
            id: 1,
            result: .error,
            detail: Data([0]) + uint32(15)
        )) == .status(VDAgentFileTransferStatus(
            id: 1,
            result: .error,
            detail: .glibIO(errorCode: 15)
        )))
        #expect(try codec.decode(status(
            id: 2,
            result: .notEnoughSpace,
            detail: uint64(123)
        )) == .status(VDAgentFileTransferStatus(
            id: 2,
            result: .notEnoughSpace,
            detail: .diskFreeSpace(123)
        )))
    }

    @Test func rejectsUnsafeNamesMalformedDetailsAndChunkBounds() throws {
        let codec = VDAgentFileTransferCodec(limits: .init(maximumChunkBytes: 3))
        for name in ["", ".", "..", "a/b", "a\\b", "bad\nname"] {
            #expect(throws: WireError.self) {
                try codec.encodeStart(id: 1, name: name, size: 0)
            }
        }
        #expect(throws: WireError.messageTooLarge(actual: 4, maximum: 3)) {
            try codec.encodeData(id: 1, data: Data(repeating: 0, count: 4))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try codec.decode(status(id: 1, result: .success, detail: Data([0])))
        }
        #expect(throws: WireError.invalidEnum(
            type: "VDAgentFileTransferErrorType",
            value: 1
        )) {
            try codec.decode(status(
                id: 1,
                result: .error,
                detail: Data([1]) + uint32(0)
            ))
        }
        let malformedData = VDAgentMessage(
            type: VDAgentMessageType.fileTransferData.rawValue,
            data: uint32(1) + uint64(2) + Data([1])
        )
        #expect(throws: WireError.invalidSize(2)) {
            try codec.decode(malformedData)
        }
    }

    private func status(
        id: UInt32,
        result: VDAgentFileTransferResult,
        detail: Data = Data()
    ) -> VDAgentMessage {
        VDAgentMessage(
            type: VDAgentMessageType.fileTransferStatus.rawValue,
            data: uint32(id) + uint32(result.rawValue) + detail
        )
    }

    private func uint32(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }

    private func uint64(_ value: UInt64) -> Data {
        var writer = ByteWriter()
        writer.writeUInt64LE(value)
        return writer.data
    }
}

private extension VDAgentFileTransferResult {
    static let allCasesForTesting: [Self] = [
        .canSendData,
        .cancelled,
        .error,
        .success,
        .notEnoughSpace,
        .sessionLocked,
        .agentNotConnected,
        .disabled,
    ]
}
