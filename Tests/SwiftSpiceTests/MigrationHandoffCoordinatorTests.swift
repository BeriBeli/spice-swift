import Testing
@testable import SpiceProtocol
@testable import SwiftSpice

@Suite("Migration handoff coordinator")
struct MigrationHandoffCoordinatorTests {
    @Test func newerBeginCancelsOldAndIgnoresItsLateCompletion() throws {
        var coordinator = MigrationHandoffCoordinator()
        let firstActions = coordinator.receive(.begin(destination(host: "first")))
        let first = try #require(preparedOffer(in: firstActions))
        let secondActions = coordinator.receive(.begin(destination(host: "second")))
        let second = try #require(preparedOffer(in: secondActions))

        #expect(second.id != first.id)
        #expect(secondActions.contains(.emit(.cancelled(first))))
        #expect(secondActions.contains(.cancel(first)))
        #expect(coordinator.preparationCompleted(
            offerID: first.id,
            acceptedSeamless: false
        ).isEmpty)
        #expect(coordinator.preparationCompleted(
            offerID: second.id,
            acceptedSeamless: false
        ) == [
            .emit(.ready(second, seamless: false)),
            .send(.connected),
        ])
    }

    @Test func seamlessPreparationCommitsOnlyAfterChannelBoundaries() throws {
        var coordinator = MigrationHandoffCoordinator()
        let start = coordinator.receive(.beginSeamless(
            destination: destination(host: "target"),
            sourceVersion: 3
        ))
        let offer = try #require(preparedOffer(in: start))

        #expect(coordinator.preparationCompleted(
            offerID: offer.id,
            acceptedSeamless: true
        ) == [
            .emit(.ready(offer, seamless: true)),
            .send(.connectedSeamless),
        ])
        #expect(coordinator.receive(.end) == [
            .protocolViolation("migration end received for a seamless target"),
        ])
        #expect(coordinator.beginSeamlessCommit(offerID: offer.id) == [
            .emit(.committing(offer)),
        ])
        #expect(coordinator.handoffCompleted(offerID: offer.id) == [
            .emit(.completed(offer)),
        ])
        #expect(coordinator.state == .idle)
    }

    @Test func cancelInvalidatesPreparationAndEndBeforeReadyIsViolation() throws {
        var coordinator = MigrationHandoffCoordinator()
        #expect(coordinator.receive(.end) == [
            .protocolViolation("migration end received without a prepared target"),
        ])

        let start = coordinator.receive(.begin(destination(host: "target")))
        let offer = try #require(preparedOffer(in: start))
        #expect(coordinator.receive(.cancel) == [
            .emit(.cancelled(offer)),
            .cancel(offer),
        ])
        #expect(coordinator.preparationFailed(
            offerID: offer.id,
            reason: "late"
        ).isEmpty)
        #expect(coordinator.state == .idle)
    }

    @Test func switchHostCancelsPreparedTargetBeforeStarting() throws {
        var coordinator = MigrationHandoffCoordinator()
        let start = coordinator.receive(.begin(destination(host: "old")))
        let old = try #require(preparedOffer(in: start))
        _ = coordinator.preparationCompleted(offerID: old.id, acceptedSeamless: false)

        let actions = coordinator.receive(.switchHost(destination(host: "new")))
        let switched = try #require(actions.compactMap { action -> SpiceMigrationOffer? in
            if case let .switchHost(offer) = action { return offer }
            return nil
        }.first)
        #expect(actions.prefix(2) == [
            .emit(.cancelled(old)),
            .cancel(old),
        ])
        #expect(actions.contains(.emit(.switching(switched))))
        #expect(coordinator.state == .switching(switched))
    }

    private func destination(host: String) -> SpiceProtocol.SpiceMigrationDestination {
        SpiceProtocol.SpiceMigrationDestination(
            host: host,
            port: 5_900,
            securePort: 0,
            certificateSubject: nil
        )
    }

    private func preparedOffer(
        in actions: [MigrationHandoffCoordinator.Action]
    ) -> SpiceMigrationOffer? {
        actions.compactMap { action in
            if case let .prepare(offer) = action { return offer }
            return nil
        }.first
    }
}
