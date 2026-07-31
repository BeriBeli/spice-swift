import Foundation
import SwiftSpice

package struct ViewerPlaybackStatus: Sendable, Equatable {
    package enum Phase: Sendable, Equatable {
        case unavailable
        case waiting
        case active(SpicePlaybackConfiguration)
        case stopped
        case failed(String)
    }

    package private(set) var phase: Phase = .unavailable
    package private(set) var isMuted = false
    package private(set) var resynchronizations = 0
    package private(set) var oversizedDrops = 0
    package private(set) var underruns = 0
    package private(set) var droppedMilliseconds: UInt64 = 0

    package static var waiting: Self {
        var status = Self()
        status.phase = .waiting
        return status
    }

    package mutating func consume(_ event: SpiceAudioPlaybackSinkEvent) {
        switch event {
        case let .started(configuration):
            phase = .active(configuration)
        case .stopped:
            phase = .stopped
        case let .muteChanged(muted):
            isMuted = muted
        case let .overflowResynchronized(milliseconds):
            resynchronizations &+= 1
            droppedMilliseconds &+= UInt64(milliseconds)
        case let .oversizedPacketDropped(milliseconds):
            oversizedDrops &+= 1
            droppedMilliseconds &+= UInt64(milliseconds)
        case .underrun:
            underruns &+= 1
        case let .failed(error):
            phase = .failed(error.description)
        }
    }

    package var label: String {
        let prefix = isMuted ? "Muted" : "Audio"
        return switch phase {
        case .unavailable:
            "No Playback"
        case .waiting:
            "\(prefix) Waiting"
        case let .active(configuration):
            "\(prefix) · \(configuration.sampleRate / 1_000) kHz · \(configuration.channels) ch"
        case .stopped:
            "\(prefix) Stopped"
        case .failed:
            "Audio Error"
        }
    }

    package var systemImage: String {
        if isMuted { return "speaker.slash.fill" }
        return switch phase {
        case .unavailable: "speaker.slash"
        case .waiting: "speaker.wave.1"
        case .active: "speaker.wave.2.fill"
        case .stopped: "speaker"
        case .failed: "speaker.badge.exclamationmark"
        }
    }

    package var diagnosticSummary: String {
        "Resyncs: \(resynchronizations) · Oversized drops: \(oversizedDrops) · Underruns: \(underruns) · Dropped: \(droppedMilliseconds) ms"
    }
}
