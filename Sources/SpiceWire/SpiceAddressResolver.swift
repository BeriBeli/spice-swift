package struct SpiceAddressResolver: Sendable {
    package let messageSize: Int

    package init(messageSize: Int) throws(WireError) {
        guard messageSize >= 0 else {
            throw .invalidSize(messageSize)
        }
        self.messageSize = messageSize
    }

    package func resolve(
        _ address: UInt64,
        minimumSize: Int
    ) throws(WireError) -> Range<Int> {
        guard minimumSize >= 0 else {
            throw .invalidSize(minimumSize)
        }
        guard address <= UInt64(Int.max) else {
            throw .invalidOffset(address)
        }
        let start = Int(address)
        let (end, overflow) = start.addingReportingOverflow(minimumSize)
        guard !overflow else {
            throw .integerOverflow
        }
        guard start <= messageSize, end <= messageSize else {
            throw .invalidOffset(address)
        }
        return start..<end
    }
}
