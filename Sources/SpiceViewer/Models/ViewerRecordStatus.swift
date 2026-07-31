import Foundation
import SwiftSpice

package struct ViewerRecordStatus: Sendable, Equatable {
    package enum Phase: Sendable, Equatable {
        case unavailable
        case disabled
        case requestingPermission
        case waiting
        case active(SpiceRecordConfiguration)
        case stopped
        case denied
        case restricted
        case failed(String)
    }

    package var phase: Phase = .unavailable
    package var isMuted = false
    package var overflows = 0
    package var droppedMilliseconds: UInt64 = 0

    package static let disabled = ViewerRecordStatus(phase: .disabled)
    package static let requestingPermission = ViewerRecordStatus(phase: .requestingPermission)
    package static let waiting = ViewerRecordStatus(phase: .waiting)
    package static let denied = ViewerRecordStatus(phase: .denied)
    package static let restricted = ViewerRecordStatus(phase: .restricted)

    package mutating func consume(_ event: SpiceAudioCaptureSourceEvent) {
        switch event {
        case let .started(configuration):
            phase = .active(configuration)
        case .stopped:
            phase = .stopped
        case let .overflowDropped(milliseconds):
            overflows &+= 1
            droppedMilliseconds &+= UInt64(milliseconds)
        case .volumeChanged:
            break
        case let .muteChanged(muted):
            isMuted = muted
        case let .failed(error):
            phase = .failed(error.description)
        }
    }

    package var label: String {
        switch phase {
        case .unavailable:
            "No Mic Channel"
        case .disabled:
            "Mic Off"
        case .requestingPermission:
            "Mic Permission…"
        case .waiting:
            "Mic Waiting"
        case let .active(configuration):
            "\(isMuted ? "Mic Muted" : "Mic") · \(configuration.sampleRate / 1_000) kHz · \(configuration.channels) ch"
        case .stopped:
            "Mic Stopped"
        case .denied:
            "Mic Denied"
        case .restricted:
            "Mic Restricted"
        case .failed:
            "Mic Error"
        }
    }

    package var systemImage: String {
        switch phase {
        case .unavailable, .disabled, .stopped:
            "mic.slash"
        case .requestingPermission, .waiting:
            "mic.badge.plus"
        case .active:
            isMuted ? "mic.slash.fill" : "mic.fill"
        case .denied, .restricted, .failed:
            "mic.badge.xmark"
        }
    }

    package var diagnosticSummary: String {
        switch phase {
        case let .failed(reason):
            "\(reason); overflows \(overflows), dropped \(droppedMilliseconds) ms"
        case .denied:
            "Microphone access was denied. Enable it in System Settings to capture audio."
        case .restricted:
            "Microphone access is restricted by the system."
        default:
            "Capture overflows \(overflows), dropped \(droppedMilliseconds) ms"
        }
    }

    package var canEnable: Bool {
        phase == .disabled || phase == .denied
    }

    package var canDisable: Bool {
        switch phase {
        case .requestingPermission, .waiting, .active, .stopped, .failed:
            true
        case .unavailable, .disabled, .denied, .restricted:
            false
        }
    }
}
