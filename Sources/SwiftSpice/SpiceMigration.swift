import Foundation
import SpiceProtocol

public struct SpiceMigrationDestination: Sendable, Equatable {
    public let host: String
    public let port: UInt16?
    public let securePort: UInt16?
    public let certificateSubject: String?

    public init(
        host: String,
        port: UInt16?,
        securePort: UInt16?,
        certificateSubject: String?
    ) {
        self.host = host
        self.port = port
        self.securePort = securePort
        self.certificateSubject = certificateSubject
    }

    package init(_ wire: SpiceProtocol.SpiceMigrationDestination) {
        self.init(
            host: wire.host,
            port: wire.port == 0 ? nil : wire.port,
            securePort: wire.securePort == 0 ? nil : wire.securePort,
            certificateSubject: wire.certificateSubject
        )
    }
}

public enum SpiceMigrationMode: Sendable, Equatable {
    case semiSeamless
    case seamless(sourceVersion: UInt32)
    case switchHost
}

public struct SpiceMigrationOffer: Sendable, Equatable {
    public let id: UInt64
    public let destination: SpiceMigrationDestination
    public let mode: SpiceMigrationMode

    public init(
        id: UInt64,
        destination: SpiceMigrationDestination,
        mode: SpiceMigrationMode
    ) {
        self.id = id
        self.destination = destination
        self.mode = mode
    }
}

public enum SpiceMigrationEvent: Sendable, Equatable {
    case preparing(SpiceMigrationOffer)
    case ready(SpiceMigrationOffer, seamless: Bool)
    case cancelled(SpiceMigrationOffer)
    case committing(SpiceMigrationOffer)
    case switching(SpiceMigrationOffer)
    case completed(SpiceMigrationOffer)
    case failed(SpiceMigrationOffer?, reason: String)
}

package protocol SpiceMigrationHandoffExecuting: Sendable {
    func prepare(_ offer: SpiceMigrationOffer) async throws -> Bool
    func commit(_ offer: SpiceMigrationOffer) async throws
    func switchHost(_ offer: SpiceMigrationOffer) async throws
    func cancel(_ offer: SpiceMigrationOffer) async
}

package struct MigrationHandoffCoordinator: Sendable {
    package enum State: Sendable, Equatable {
        case idle
        case preparing(SpiceMigrationOffer)
        case ready(SpiceMigrationOffer, seamless: Bool)
        case committing(SpiceMigrationOffer)
        case switching(SpiceMigrationOffer)
    }

    package enum Action: Sendable, Equatable {
        case cancel(SpiceMigrationOffer)
        case prepare(SpiceMigrationOffer)
        case commit(SpiceMigrationOffer)
        case switchHost(SpiceMigrationOffer)
        case send(SpiceMainMigrationReply)
        case emit(SpiceMigrationEvent)
        case protocolViolation(String)
    }

    package private(set) var state: State = .idle
    private var nextOfferID: UInt64 = 1

    package mutating func receive(
        _ command: SpiceMainMigrationCommand
    ) -> [Action] {
        switch command {
        case let .begin(destination):
            return start(
                destination: SpiceMigrationDestination(destination),
                mode: .semiSeamless
            )
        case let .beginSeamless(destination, sourceVersion):
            return start(
                destination: SpiceMigrationDestination(destination),
                mode: .seamless(sourceVersion: sourceVersion)
            )
        case let .switchHost(destination):
            var actions = cancelCurrent(emit: true)
            let offer = makeOffer(
                destination: SpiceMigrationDestination(destination),
                mode: .switchHost
            )
            state = .switching(offer)
            actions.append(.emit(.switching(offer)))
            actions.append(.switchHost(offer))
            return actions
        case .cancel:
            return cancelCurrent(emit: true)
        case .end:
            guard case let .ready(offer, seamless) = state else {
                return [.protocolViolation("migration end received without a prepared target")]
            }
            guard !seamless else {
                return [.protocolViolation(
                    "migration end received for a seamless target"
                )]
            }
            state = .committing(offer)
            return [.emit(.committing(offer)), .commit(offer)]
        case .destinationSeamlessAccepted, .destinationSeamlessRejected:
            return [.protocolViolation(
                "destination seamless reply received outside a target migration handshake"
            )]
        }
    }

    package mutating func preparationCompleted(
        offerID: UInt64,
        acceptedSeamless: Bool
    ) -> [Action] {
        guard case let .preparing(offer) = state, offer.id == offerID else { return [] }
        let seamless: Bool
        if case .seamless = offer.mode {
            seamless = acceptedSeamless
        } else {
            seamless = false
        }
        state = .ready(offer, seamless: seamless)
        return [
            .emit(.ready(offer, seamless: seamless)),
            .send(seamless ? .connectedSeamless : .connected),
        ]
    }

    package mutating func preparationFailed(
        offerID: UInt64,
        reason: String
    ) -> [Action] {
        guard case let .preparing(offer) = state, offer.id == offerID else { return [] }
        state = .idle
        return [.emit(.failed(offer, reason: reason)), .send(.connectError)]
    }

    package mutating func handoffCompleted(offerID: UInt64) -> [Action] {
        let offer: SpiceMigrationOffer
        switch state {
        case let .committing(current) where current.id == offerID:
            offer = current
        case let .switching(current) where current.id == offerID:
            offer = current
        default:
            return []
        }
        state = .idle
        return [.emit(.completed(offer))]
    }

    package mutating func beginSeamlessCommit(offerID: UInt64) -> [Action] {
        guard case let .ready(offer, seamless) = state,
              offer.id == offerID,
              seamless else {
            return []
        }
        state = .committing(offer)
        return [.emit(.committing(offer))]
    }

    package mutating func handoffFailed(
        offerID: UInt64,
        reason: String
    ) -> [Action] {
        let offer: SpiceMigrationOffer
        switch state {
        case let .committing(current) where current.id == offerID:
            offer = current
        case let .switching(current) where current.id == offerID:
            offer = current
        default:
            return []
        }
        state = .idle
        return [.emit(.failed(offer, reason: reason))]
    }

    package mutating func disconnect() -> [Action] {
        cancelCurrent(emit: false)
    }

    private mutating func start(
        destination: SpiceMigrationDestination,
        mode: SpiceMigrationMode
    ) -> [Action] {
        var actions = cancelCurrent(emit: true)
        let offer = makeOffer(destination: destination, mode: mode)
        state = .preparing(offer)
        actions.append(.emit(.preparing(offer)))
        actions.append(.prepare(offer))
        return actions
    }

    private mutating func cancelCurrent(emit: Bool) -> [Action] {
        guard state != .idle else { return [] }
        let offer: SpiceMigrationOffer
        switch state {
        case let .preparing(current), let .ready(current, _),
             let .committing(current), let .switching(current):
            offer = current
        case .idle:
            return []
        }
        state = .idle
        var actions: [Action] = []
        if emit { actions.append(.emit(.cancelled(offer))) }
        actions.append(.cancel(offer))
        return actions
    }

    private mutating func makeOffer(
        destination: SpiceMigrationDestination,
        mode: SpiceMigrationMode
    ) -> SpiceMigrationOffer {
        let id = nextOfferID
        nextOfferID &+= 1
        if nextOfferID == 0 { nextOfferID = 1 }
        return SpiceMigrationOffer(id: id, destination: destination, mode: mode)
    }
}
