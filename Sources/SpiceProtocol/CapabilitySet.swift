package protocol SpiceCapability: RawRepresentable, Sendable where RawValue == Int {}

package struct CapabilitySet<Capability: SpiceCapability>: Sendable, Equatable {
    private var words: [UInt32]

    package init(words: [UInt32] = []) {
        self.words = words
    }

    package func contains(_ capability: Capability) -> Bool {
        guard capability.rawValue >= 0 else {
            return false
        }
        let wordIndex = capability.rawValue / 32
        let bitIndex = capability.rawValue % 32
        guard wordIndex < words.count else {
            return false
        }
        return words[wordIndex] & (UInt32(1) << UInt32(bitIndex)) != 0
    }

    package mutating func insert(_ capability: Capability) {
        guard capability.rawValue >= 0 else {
            return
        }
        let wordIndex = capability.rawValue / 32
        let bitIndex = capability.rawValue % 32
        if wordIndex >= words.count {
            words.append(contentsOf: repeatElement(0, count: wordIndex - words.count + 1))
        }
        words[wordIndex] |= UInt32(1) << UInt32(bitIndex)
    }

    package var wireWords: [UInt32] {
        words
    }
}

package enum CommonCapability: Int, SpiceCapability {
    case protocolAuthSelection = 0
    case authSpice = 1
    case authSASL = 2
    case miniHeader = 3
}

package enum DisplayCapability: Int, SpiceCapability {
    case sizedStream = 0
    case monitorsConfig = 1
    case composite = 2
    case a8Surface = 3
    case streamReport = 4
    case lz4Compression = 5
    case preferredCompression = 6
    case glScanout = 7
    case multiCodec = 8
    case codecMJPEG = 9
    case codecVP8 = 10
    case codecH264 = 11
    case preferredVideoCodec = 12
    case codecVP9 = 13
    case codecH265 = 14
    case glScanout2 = 15
}

package enum MainCapability: Int, SpiceCapability {
    case semiSeamlessMigrate = 0
    case nameAndUUID = 1
    case agentConnectedTokens = 2
    case seamlessMigrate = 3
}

package enum PlaybackCapability: Int, SpiceCapability {
    case celt051 = 0
    case volume = 1
    case latency = 2
    case opus = 3
}

package enum RecordCapability: Int, SpiceCapability {
    case celt051 = 0
    case volume = 1
    case opus = 2
}
