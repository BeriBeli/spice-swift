import Foundation
import SwiftSpice

package struct ViewerClipboardStatus: Sendable, Equatable {
    package enum Phase: Sendable, Equatable {
        case unavailable
        case disabled
        case waiting
        case ready
        case failed(String)
    }

    package enum Ownership: Sendable, Equatable {
        case none
        case local(byteCount: Int)
        case guest(byteCount: Int)
    }

    package var phase: Phase = .unavailable
    package var ownership: Ownership = .none
    package var localOffers = 0
    package var guestUpdates = 0
    package var oversizedRejects = 0

    package static let disabled = ViewerClipboardStatus(phase: .disabled)
    package static let waiting = ViewerClipboardStatus(phase: .waiting)

    package mutating func consume(_ event: SpiceClipboardEvent) {
        switch event {
        case .ready:
            phase = .ready
        case .unavailable:
            phase = .waiting
            ownership = .none
        case let .guestText(text):
            guestUpdates &+= 1
            ownership = .guest(byteCount: text.utf8.count)
        case let .localTextOffered(byteCount):
            localOffers &+= 1
            ownership = .local(byteCount: byteCount)
        case .oversizedLocalText:
            oversizedRejects &+= 1
            ownership = .none
        case let .failed(error):
            phase = .failed(error.description)
        }
    }

    package var label: String {
        switch phase {
        case .unavailable:
            "No Clipboard"
        case .disabled:
            "Clipboard Off"
        case .waiting:
            "Clipboard Waiting"
        case .ready:
            switch ownership {
            case .none:
                "Clipboard Ready"
            case .local:
                "Clipboard Host"
            case .guest:
                "Clipboard Guest"
            }
        case .failed:
            "Clipboard Error"
        }
    }

    package var systemImage: String {
        switch phase {
        case .unavailable, .disabled:
            "clipboard"
        case .waiting:
            "clipboard.fill"
        case .ready:
            switch ownership {
            case .none: "clipboard.fill"
            case .local: "arrow.up.circle.fill"
            case .guest: "arrow.down.circle.fill"
            }
        case .failed:
            "clipboard.fill"
        }
    }

    package var diagnosticSummary: String {
        switch phase {
        case let .failed(reason):
            "\(reason); local offers \(localOffers), guest updates \(guestUpdates), oversized rejects \(oversizedRejects)"
        default:
            "UTF-8 clipboard only · Local offers \(localOffers) · Guest updates \(guestUpdates) · Oversized rejects \(oversizedRejects) · Not keyboard or IME synchronization"
        }
    }

    package var canEnable: Bool {
        switch phase {
        case .disabled, .failed:
            true
        case .unavailable, .waiting, .ready:
            false
        }
    }

    package var canDisable: Bool {
        switch phase {
        case .waiting, .ready:
            true
        case .unavailable, .disabled, .failed:
            false
        }
    }
}
