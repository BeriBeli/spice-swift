package struct AckController: Sendable {
    private var generation: UInt32?
    private var window: UInt32 = 0
    private var processedSinceAck: UInt32 = 0

    package init() {}

    package mutating func configure(generation: UInt32, window: UInt32) {
        self.generation = generation
        self.window = window
        processedSinceAck = 0
    }

    package mutating func didProcessMessage() -> Bool {
        guard generation != nil, window > 0 else {
            return false
        }
        let (next, overflow) = processedSinceAck.addingReportingOverflow(1)
        processedSinceAck = overflow ? window : next
        guard processedSinceAck >= window else {
            return false
        }
        processedSinceAck = 0
        return true
    }
}
