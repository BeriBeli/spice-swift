import Foundation
import Synchronization
import Testing
@testable import SwiftSpice

@Suite("Interaction presentation trace")
struct SpiceInteractionPresentationTraceTests {
    @Test func frameIdentityUsesTheExactFrameDeliverySequence() throws {
        let snapshot = Self.snapshot(
            revision: 9,
            frameDeliverySequence: 40,
            deliverySequence: 41
        )

        let identity = try #require(snapshot.interactionFrameIdentity)
        #expect(identity.desktopGeneration == 3)
        #expect(identity.displayChannelID == 2)
        #expect(identity.surfaceID == 7)
        #expect(identity.surfaceGeneration == 4)
        #expect(identity.frameRevision == 9)
        #expect(identity.deliverySequence == 40)
        #expect(snapshot.deliverySequence == 41)
    }

    @Test func readyLatchPreservesCursorIdentityAndRefreshesForANewFrame() throws {
        let first = Self.snapshot(
            revision: 9,
            frameDeliverySequence: 40,
            deliverySequence: 40
        )
        let cursorOnly = Self.snapshot(
            revision: 9,
            frameDeliverySequence: 40,
            deliverySequence: 41,
            cursor: SpiceCursorState(x: 11, y: 12, isVisible: true, image: nil),
            damage: .rectangles([])
        )
        let nextFrame = Self.snapshot(
            revision: 10,
            frameDeliverySequence: 42,
            deliverySequence: 42
        )
        let latch = SpiceDesktopReadyLatch()

        #expect(latch.offer(first))
        let firstReady = try #require(latch.takeReady(at: ContinuousClock().now))
        let firstContext = try #require(firstReady.interactionContext(
            selectionNanoseconds: SpiceInteractionHostClock.nowNanoseconds()
        ))

        latch.restoreIfEmpty(firstReady)
        #expect(!latch.offer(cursorOnly))
        let cursorReady = try #require(latch.takeReady(at: ContinuousClock().now))
        let cursorContext = try #require(cursorReady.interactionContext(
            selectionNanoseconds: SpiceInteractionHostClock.nowNanoseconds()
        ))
        #expect(cursorReady.snapshot.deliverySequence == 41)
        #expect(cursorReady.snapshot.cursor?.x == 11)
        #expect(cursorContext.identity == firstContext.identity)
        #expect(cursorContext.readyNanoseconds == firstContext.readyNanoseconds)

        #expect(latch.offer(nextFrame))
        let nextReady = try #require(latch.takeReady(at: ContinuousClock().now))
        let nextContext = try #require(nextReady.interactionContext(
            selectionNanoseconds: SpiceInteractionHostClock.nowNanoseconds()
        ))
        #expect(nextContext.identity.frameRevision == 10)
        #expect(nextContext.identity.deliverySequence == 42)
        #expect(nextContext.identity != cursorContext.identity)
        #expect(nextContext.readyNanoseconds > cursorContext.readyNanoseconds)
    }

    @Test func selectedEvidenceRequiresAnActualFramebufferPresentation() throws {
        let diagnostics = SpicePresentationDiagnostics()
        let observer = RecordingInteractionPresentationObserver()
        #expect(diagnostics.installInteractionPresentationObserver(observer))
        defer { diagnostics.removeInteractionPresentationObserver(observer) }

        let revision = SpiceFrameRevision(
            surface: SpiceSurfaceIdentity(
                displayChannelID: 2,
                surfaceID: 7,
                generation: 4
            ),
            value: 9
        )
        let identity = try #require(Self.snapshot(
            revision: 9,
            frameDeliverySequence: 40,
            deliverySequence: 41
        ).interactionFrameIdentity)
        let context = SpiceInteractionPresentationContext(
            identity: identity,
            readyNanoseconds: 100,
            selectionNanoseconds: 110
        )

        let cursorOnly: Int? = SpiceDesktopPresentationPolicy
            .withFramebufferPresentationIfNeeded(
                selectedRevision: revision,
                updateRevision: revision,
                requiresRedraw: false
            ) {
                diagnostics.recordInteractionSelected(context)
                return 1
            }
        #expect(cursorOnly == nil)
        #expect(observer.events.isEmpty)

        let framebuffer: Int? = SpiceDesktopPresentationPolicy
            .withFramebufferPresentationIfNeeded(
                selectedRevision: revision,
                updateRevision: revision,
                requiresRedraw: true
            ) {
                diagnostics.recordInteractionSelected(context)
                return 1
            }
        #expect(framebuffer == 1)
        #expect(observer.events == [.selected(context)])
    }

    @Test func diagnosticsForwardEveryExactPresentationIdentityUnchanged() {
        let diagnostics = SpicePresentationDiagnostics()
        let observer = RecordingInteractionPresentationObserver()
        #expect(diagnostics.installInteractionPresentationObserver(observer))
        defer { diagnostics.removeInteractionPresentationObserver(observer) }

        let first = Self.identity(revision: 9, deliverySequence: 40)
        let second = Self.identity(revision: 10, deliverySequence: 42)
        let context = SpiceInteractionPresentationContext(
            identity: first,
            readyNanoseconds: 100,
            selectionNanoseconds: 110
        )
        diagnostics.recordInteractionSelected(context)
        diagnostics.recordInteractionCommitted(identity: second, at: 120)
        diagnostics.recordInteractionPresented(identity: first, at: 130)
        diagnostics.recordInteractionPresentationDropped(identity: second)

        #expect(observer.events == [
            .selected(context),
            .committed(second, 120),
            .presented(first, 130),
            .dropped(second),
        ])
    }

    @Test func callbackLocalCoreAnimationMappingIsCheckedAndFailClosed() {
        let continuousNow: UInt64 = 600_000_000_000_000
        #expect(SpiceInteractionHostClock.nanoseconds(
            forCoreAnimationTime: 99.875,
            mediaTimeNow: 100,
            continuousNanosecondsNow: continuousNow
        ) == continuousNow - 125_000_000)

        for invalid in [0, -1, .nan, .infinity] as [TimeInterval] {
            #expect(SpiceInteractionHostClock.nanoseconds(
                forCoreAnimationTime: invalid,
                mediaTimeNow: 100,
                continuousNanosecondsNow: continuousNow
            ) == nil)
        }
        #expect(SpiceInteractionHostClock.nanoseconds(
            forCoreAnimationTime: 100.001,
            mediaTimeNow: 100,
            continuousNanosecondsNow: continuousNow
        ) == nil)
        #expect(SpiceInteractionHostClock.nanoseconds(
            forCoreAnimationTime: 1,
            mediaTimeNow: 3,
            continuousNanosecondsNow: 1_000_000_000
        ) == nil)
    }
}

private extension SpiceInteractionPresentationTraceTests {
    static func snapshot(
        revision: UInt64,
        frameDeliverySequence: UInt64,
        deliverySequence: UInt64,
        cursor: SpiceCursorState? = nil,
        damage: SpiceDamageRegion = .full
    ) -> SpiceDesktopSnapshot {
        let frame = SpiceFrame(
            surfaceID: 7,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixels: Data(repeating: UInt8(revision), count: 16)
        )
        let surface = SpiceSurfaceIdentity(
            displayChannelID: 2,
            surfaceID: 7,
            generation: 4
        )
        return SpiceDesktopSnapshot(
            generation: 3,
            frame: SpiceFrameUpdate(
                frame: frame,
                revision: SpiceFrameRevision(surface: surface, value: revision),
                damage: damage,
                deliverySequence: frameDeliverySequence
            ),
            cursor: cursor,
            pointerMode: .absolute,
            deliverySequence: deliverySequence
        )
    }

    static func identity(
        revision: UInt64,
        deliverySequence: UInt64
    ) -> SpiceInteractionFrameIdentity {
        SpiceInteractionFrameIdentity(
            desktopGeneration: 3,
            displayChannelID: 2,
            surfaceID: 7,
            surfaceGeneration: 4,
            frameRevision: revision,
            deliverySequence: deliverySequence
        )
    }
}

private final class RecordingInteractionPresentationObserver:
    SpiceInteractionPresentationObserver,
    Sendable
{
    enum Event: Sendable, Equatable {
        case selected(SpiceInteractionPresentationContext)
        case committed(SpiceInteractionFrameIdentity, UInt64)
        case presented(SpiceInteractionFrameIdentity, UInt64)
        case dropped(SpiceInteractionFrameIdentity)
    }

    private let recordedEvents = Mutex<[Event]>([])

    var events: [Event] { recordedEvents.withLock { $0 } }

    func observeSelected(_ context: SpiceInteractionPresentationContext) {
        recordedEvents.withLock { $0.append(.selected(context)) }
    }

    func observeCommitted(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    ) {
        recordedEvents.withLock { $0.append(.committed(identity, nanoseconds)) }
    }

    func observePresented(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    ) {
        recordedEvents.withLock { $0.append(.presented(identity, nanoseconds)) }
    }

    func observePresentationDropped(identity: SpiceInteractionFrameIdentity) {
        recordedEvents.withLock { $0.append(.dropped(identity)) }
    }
}
