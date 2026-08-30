import CryptoKit
import Foundation
import SwiftSpice

package enum SpiceLiveInteractionSupportError: Error, Sendable, Equatable {
    case notExplicitlyEnabled
    case incompleteConfiguration
    case invalidConfiguration
    case invalidCampaignPlan
    case invalidExecutionTransition
    case invalidRunDirectory
    case invalidTicket
    case invalidTraceProtocol
    case childFailed
    case childTimedOut
    case outputLimitExceeded
    case operationTimedOut
}

package struct SpiceLiveInteractionClusterPlan: Sendable, Equatable {
    package struct Step: Sendable, Equatable {
        package let order: UInt64
        package let actionClass: SpiceInteractionActionClass
        package let token: String
        package let checksum: UInt32
        package let pairID: String

        fileprivate init(
            order: UInt64,
            actionClass: SpiceInteractionActionClass,
            token: String,
            checksum: UInt32,
            pairID: String
        ) {
            self.order = order
            self.actionClass = actionClass
            self.token = token
            self.checksum = checksum
            self.pairID = pairID
        }

        package func requiresMotionAcknowledgement(
            for pointerMode: SpicePointerMode
        ) -> Bool {
            actionClass == .motion && pointerMode == .relative
        }

        package func inputs(for pointerMode: SpicePointerMode) -> [SpiceClientInput] {
            switch actionClass {
            case .click:
                [.mousePress(.left), .mouseRelease(.left)]
            case .key:
                [.keyDown(scanCode: 0x1e), .keyUp(scanCode: 0x1e)]
            case .motion:
                switch pointerMode {
                case .relative:
                    [.mouseMotion(dx: 1, dy: 1)]
                case .absolute:
                    [
                        .mousePosition(
                            x: 160 + (UInt32(token.prefix(2), radix: 16) ?? 0) % 64,
                            y: 120 + (UInt32(token.dropFirst(2).prefix(2), radix: 16) ?? 0) % 64,
                            displayID: 0
                        ),
                    ]
                }
            }
        }
    }

    package let clusterID: String
    package let steps: [Step]

    package init(clusterID: String) throws {
        guard SpiceLiveValidation.isCanonicalLowerHex(clusterID, count: 16) else {
            throw SpiceLiveInteractionSupportError.invalidCampaignPlan
        }
        let actions: [SpiceInteractionActionClass] = [.click, .key, .motion]
        let steps = actions.enumerated().map { offset, actionClass in
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
        guard Set(steps.map(\.token)).count == steps.count,
              Set(steps.map(\.pairID)).count == steps.count else {
            throw SpiceLiveInteractionSupportError.invalidCampaignPlan
        }
        self.clusterID = clusterID
        self.steps = steps
    }

    private static func token(
        clusterID: String,
        actionClass: SpiceInteractionActionClass,
        order: UInt64
    ) -> String {
        SpiceLiveValidation.digestHex(
            "swiftspice-live-cluster-v1:\(clusterID):\(order):\(actionClass.rawValue)",
            byteCount: 8
        )
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
              acknowledgement.nanoseconds >= waiter.notBefore else { return }
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
                } else if waiter != nil {
                    continuation.resume(
                        throwing: SpiceLiveInteractionSupportError.invalidTraceProtocol
                    )
                } else {
                    waiter = Waiter(
                        identifier: identifier,
                        epoch: epoch,
                        notBefore: nanoseconds,
                        continuation: continuation
                    )
                }
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

enum SpiceLiveValidation {
    static func isCanonicalLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func isCanonicalVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.first == 118 else { return false }
        let components = bytes.dropFirst().split(
            separator: 46,
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                return false
            }
            return component.count == 1 || component.first != 48
        }
    }

    static func digestHex(_ material: String, byteCount: Int) -> String {
        SHA256.hash(data: Data(material.utf8)).prefix(byteCount).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
