import CryptoKit
import Foundation
import SwiftSpice

package struct SpiceLiveInteractionClusterPlan: Sendable {
    package struct Step: Sendable, Equatable {
        package let order: UInt64
        package let actionClass: SpiceInteractionActionClass
        package let token: String
        package let checksum: UInt32
        package let pairID: String

        package var remoteActionClass: String { actionClass.rawValue }

        package func requiresMotionAcknowledgement(
            for pointerMode: SpicePointerMode
        ) -> Bool {
            actionClass == .motion && pointerMode == .relative
        }

        package func inputs(for pointerMode: SpicePointerMode) -> [SpiceClientInput] {
            switch actionClass {
            case .click:
                return [.mousePress(.left), .mouseRelease(.left)]
            case .key:
                return [.keyDown(scanCode: 0x1e), .keyUp(scanCode: 0x1e)]
            case .motion:
                switch pointerMode {
                case .relative:
                    return [.mouseMotion(dx: 1, dy: 1)]
                case .absolute:
                    // A deterministic cluster-specific point keeps paired
                    // versions identical while avoiding a fixed cursor
                    // coordinate across unrelated clusters.
                    let xByte = UInt32(token.prefix(2), radix: 16) ?? 0
                    let yByte = UInt32(token.dropFirst(2).prefix(2), radix: 16) ?? 0
                    return [
                        .mousePosition(
                            x: 160 + xByte % 64,
                            y: 120 + yByte % 64,
                            displayID: 0
                        ),
                    ]
                }
            }
        }
    }

    private enum Phase: Sendable {
        case ready(index: Int)
        case active(index: Int, exactPresentationRecorded: Bool)
        case completed
        case failed
    }

    private let steps: [Step]
    private var phase: Phase = .ready(index: 0)

    package init(clusterID: String) throws {
        guard Self.isCanonicalClusterID(clusterID) else {
            throw SpiceLiveInteractionSupportError.invalidIsolatedConfiguration
        }
        let actions: [SpiceInteractionActionClass] = [.click, .key, .motion]
        steps = actions.enumerated().map { offset, actionClass in
            let order = UInt64(offset + 1)
            let token = Self.token(
                clusterID: clusterID,
                actionClass: actionClass,
                order: order
            )
            return Step(
                order: order,
                actionClass: actionClass,
                token: token,
                checksum: Self.markerChecksum(token: token),
                pairID: "live-\(clusterID)-\(order)-\(actionClass.rawValue)"
            )
        }
        guard Set(steps.map(\.token)).count == steps.count else {
            throw SpiceLiveInteractionSupportError.invalidIsolatedConfiguration
        }
    }

    package mutating func beginNextStep() throws -> Step {
        guard case let .ready(index) = phase, steps.indices.contains(index) else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        phase = .active(index: index, exactPresentationRecorded: false)
        return steps[index]
    }

    package mutating func recordExactPresentation(order: UInt64) throws {
        guard case let .active(index, false) = phase,
              steps[index].order == order
        else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        phase = .active(index: index, exactPresentationRecorded: true)
    }

    package mutating func recordAppendCompleted(order: UInt64) throws {
        guard case let .active(index, true) = phase,
              steps[index].order == order
        else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let next = index + 1
        phase = steps.indices.contains(next) ? .ready(index: next) : .completed
    }

    package mutating func failCurrentStep() {
        phase = .failed
    }

    private static func isCanonicalClusterID(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func token(
        clusterID: String,
        actionClass: SpiceInteractionActionClass,
        order: UInt64
    ) -> String {
        let material = "swiftspice-live-cluster-v1:\(clusterID):\(order):\(actionClass.rawValue)"
        return SHA256.hash(data: Data(material.utf8)).prefix(8).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func markerChecksum(token: String) -> UInt32 {
        SHA256.hash(data: Data(token.utf8)).prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }
}

package actor SpiceLiveMotionAcknowledgementMonitor {
    package struct Epoch: Sendable, Equatable {
        fileprivate let sequence: UInt64
    }

    private struct Acknowledgement: Sendable {
        let sequence: UInt64
        let nanoseconds: UInt64
    }

    private struct Waiter: @unchecked Sendable {
        let identifier: UUID
        let epoch: Epoch
        let notBefore: UInt64
        let continuation: CheckedContinuation<UInt64, any Error>
    }

    private var sequence: UInt64 = 0
    private var latest: Acknowledgement?
    private var waiter: Waiter?

    package init() {}

    package func beginCleanEpoch() throws -> Epoch {
        guard waiter == nil else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return Epoch(sequence: sequence)
    }

    package func recordAcknowledgement(at nanoseconds: UInt64) {
        guard sequence < UInt64.max else { return }
        sequence += 1
        let acknowledgement = Acknowledgement(
            sequence: sequence,
            nanoseconds: nanoseconds
        )
        latest = acknowledgement
        guard let waiter,
              acknowledgement.sequence > waiter.epoch.sequence,
              acknowledgement.nanoseconds >= waiter.notBefore
        else {
            return
        }
        self.waiter = nil
        waiter.continuation.resume(returning: acknowledgement.nanoseconds)
    }

    package func waitForAcknowledgement(
        after epoch: Epoch,
        notBefore nanoseconds: UInt64
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        if let latest,
           latest.sequence > epoch.sequence,
           latest.nanoseconds >= nanoseconds {
            return latest.nanoseconds
        }
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard waiter == nil else {
                    continuation.resume(
                        throwing: SpiceLiveInteractionSupportError.invalidTraceProtocol
                    )
                    return
                }
                waiter = Waiter(
                    identifier: identifier,
                    epoch: epoch,
                    notBefore: nanoseconds,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    private func cancelWaiter(_ identifier: UUID) {
        guard let waiter, waiter.identifier == identifier else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: CancellationError())
    }
}
