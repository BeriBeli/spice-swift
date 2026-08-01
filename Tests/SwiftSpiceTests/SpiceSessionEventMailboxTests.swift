import Foundation
import Testing
@testable import SwiftSpice

@Suite("SpiceSession event mailbox")
struct SpiceSessionEventMailboxTests {
    @Test func coalescesOneThousandPendingFramesToTheLatestRevision() async throws {
        let mailbox = SpiceSessionEventMailbox(maximumPendingFrames: 64)
        for revision in 0 ..< 1_000 {
            mailbox.send(.frame(Self.frame(
                surfaceID: 7,
                marker: UInt8(truncatingIfNeeded: revision)
            )))
        }
        mailbox.send(.keyboardModifiers(0x0200))

        let frame = try #require(Self.frame(from: await mailbox.next()))
        #expect(frame.surfaceID == 7)
        #expect(frame.pixels[0] == UInt8(truncatingIfNeeded: 999))
        #expect(await mailbox.next() == .keyboardModifiers(0x0200))
        mailbox.finish()
    }

    @Test func framePressureNeverEvictsControlState() async throws {
        let mailbox = SpiceSessionEventMailbox(maximumPendingFrames: 4)
        for surfaceID in 0 ..< 10 {
            mailbox.send(.frame(Self.frame(
                surfaceID: UInt32(surfaceID),
                marker: UInt8(surfaceID)
            )))
        }
        mailbox.send(.mouseMode(supported: 3, current: 2))

        var surfaceIDs: [UInt32] = []
        for _ in 0 ..< 4 {
            surfaceIDs.append(try #require(Self.frame(from: await mailbox.next())).surfaceID)
        }
        #expect(surfaceIDs == [6, 7, 8, 9])
        #expect(await mailbox.next() == .mouseMode(supported: 3, current: 2))
        mailbox.finish()
    }

    @Test func controlBoundaryPreventsLaterFrameFromMovingAhead() async throws {
        let mailbox = SpiceSessionEventMailbox(maximumPendingFrames: 4)
        mailbox.send(.frame(Self.frame(surfaceID: 1, marker: 1)))
        mailbox.send(.keyboardModifiers(2))
        mailbox.send(.frame(Self.frame(surfaceID: 1, marker: 3)))

        #expect(try #require(Self.frame(from: await mailbox.next())).pixels[0] == 1)
        #expect(await mailbox.next() == .keyboardModifiers(2))
        #expect(try #require(Self.frame(from: await mailbox.next())).pixels[0] == 3)
        mailbox.finish()
    }

    @Test func destroyPurgesOlderPendingFrameBeforeSameIDRecreation() async throws {
        let mailbox = SpiceSessionEventMailbox(maximumPendingFrames: 4)
        mailbox.send(.frame(Self.frame(surfaceID: 5, marker: 1)))
        mailbox.send(.surfaceDestroyed(5))
        mailbox.send(.frame(Self.frame(surfaceID: 5, marker: 2)))

        #expect(await mailbox.next() == .surfaceDestroyed(5))
        let recreated = try #require(Self.frame(from: await mailbox.next()))
        #expect(recreated.surfaceID == 5)
        #expect(recreated.pixels[0] == 2)
        mailbox.finish()
    }

    @Test func identicalSurfaceIDsOnDifferentDisplayChannelsDoNotCoalesce() async throws {
        let mailbox = SpiceSessionEventMailbox(maximumPendingFrames: 4)
        mailbox.send(
            .frame(Self.frame(surfaceID: 5, marker: 1)),
            displayChannelID: 1
        )
        mailbox.send(
            .frame(Self.frame(surfaceID: 5, marker: 2)),
            displayChannelID: 2
        )

        #expect(try #require(Self.frame(from: await mailbox.next())).pixels[0] == 1)
        #expect(try #require(Self.frame(from: await mailbox.next())).pixels[0] == 2)
        mailbox.finish()
    }

    @Test func destroyOnlyPurgesMatchingDisplayChannelFrame() async throws {
        let mailbox = SpiceSessionEventMailbox(maximumPendingFrames: 4)
        mailbox.send(
            .frame(Self.frame(surfaceID: 5, marker: 1)),
            displayChannelID: 1
        )
        mailbox.send(
            .frame(Self.frame(surfaceID: 5, marker: 2)),
            displayChannelID: 2
        )
        mailbox.send(.surfaceDestroyed(5), displayChannelID: 1)

        #expect(try #require(Self.frame(from: await mailbox.next())).pixels[0] == 2)
        #expect(await mailbox.next() == .surfaceDestroyed(5))
        mailbox.finish()
    }

    private static func frame(surfaceID: UInt32, marker: UInt8) -> SpiceFrame {
        SpiceFrame(
            surfaceID: surfaceID,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixels: Data([marker, 0, 0, 255])
        )
    }

    private static func frame(from event: SpiceSessionEvent?) -> SpiceFrame? {
        guard case let .frame(frame) = event else { return nil }
        return frame
    }
}
