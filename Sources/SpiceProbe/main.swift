import Foundation
import SwiftSpice

@main
struct SpiceProbe {
    static func main() async {
        do {
            let configuration = try parseArguments()
            let password = ProcessInfo.processInfo.environment["SPICE_PASSWORD"] ?? ""
            let credentials = SpiceCredentials(password: password)
            let session = SpiceSession()
            let info = try await session.connect(
                endpoint: configuration.endpoint,
                credentials: credentials
            )

            print("SPICE session \(info.sessionID) connected")
            print("mouse modes: supported=\(info.supportedMouseModes) current=\(info.currentMouseMode)")
            for channel in info.channels {
                print("channel type=\(channel.type) id=\(channel.id)")
            }
            if let seconds = configuration.observeSeconds {
                try await observe(
                    session: session,
                    seconds: seconds,
                    exerciseInput: configuration.exerciseInput
                )
            }
            await session.disconnect()
        } catch {
            FileHandle.standardError.write(Data("spice-probe: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func parseArguments() throws -> Configuration {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2, let port = UInt16(arguments[1]) else {
            throw ProbeError.usage
        }
        let tlsPolicy: TLSTrustPolicy?
        if arguments.contains("--tls-insecure-for-testing-only") {
            tlsPolicy = .insecureForTestingOnly
        } else if arguments.contains("--tls") {
            tlsPolicy = .system
        } else {
            tlsPolicy = nil
        }
        return Configuration(
            endpoint: SpiceEndpoint(host: arguments[0], port: port, tlsPolicy: tlsPolicy),
            observeSeconds: try optionalUInt64(after: "--observe-seconds", in: arguments),
            exerciseInput: arguments.contains("--exercise-input")
        )
    }

    private static func optionalUInt64(
        after flag: String,
        in arguments: [String]
    ) throws -> UInt64? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        guard arguments.indices.contains(index + 1),
              let value = UInt64(arguments[index + 1]),
              value > 0 else {
            throw ProbeError.usage
        }
        return value
    }

    private static func observe(
        session: SpiceSession,
        seconds: UInt64,
        exerciseInput: Bool
    ) async throws {
        let observations = ProbeObservations()
        let eventTask = Task {
            for await event in session.events {
                await observations.record(event)
                print(description(of: event))
            }
        }
        defer { eventTask.cancel() }

        if exerciseInput {
            try await session.send(.keyDown(scanCode: 0x1e))
            try await session.send(.keyUp(scanCode: 0x1e))
            for _ in 0..<8 {
                try await session.send(.mouseMotion(dx: 1, dy: 1))
            }
        }

        try await Task.sleep(for: .seconds(seconds))
        let summary = await observations.summary()
        print(
            "observed: frames=\(summary.frames) cursors=\(summary.cursors) "
                + "keyboard=\(summary.keyboardEvents) motion-acks=\(summary.motionAcknowledgements)"
        )
        guard summary.frames > 0 else {
            throw ProbeError.missingObservation("Display frame")
        }
        if exerciseInput, summary.motionAcknowledgements == 0 {
            throw ProbeError.missingObservation("Inputs mouse-motion acknowledgement")
        }
    }

    private static func description(of event: SpiceSessionEvent) -> String {
        switch event {
        case let .frame(frame):
            "frame surface=\(frame.surfaceID) size=\(frame.width)x\(frame.height) "
                + "bytes=\(frame.pixels.count)"
        case let .surfaceDestroyed(surfaceID):
            "surface destroyed id=\(surfaceID)"
        case let .displayConfiguration(configuration):
            "display configuration channel=\(configuration.channelID) "
                + "monitors=\(configuration.monitors.count)"
        case let .cursor(cursor):
            "cursor position=\(cursor.x),\(cursor.y) visible=\(cursor.isVisible)"
        case let .keyboardModifiers(modifiers):
            "keyboard modifiers=\(modifiers)"
        case .mouseMotionAcknowledged:
            "mouse motion acknowledged"
        case let .mouseMode(supported, current):
            "mouse mode supported=\(supported) current=\(current)"
        case let .migration(event):
            "migration event=\(event)"
        case let .failed(error):
            "session failed: \(error)"
        case .disconnected:
            "session disconnected"
        }
    }
}

private struct Configuration {
    let endpoint: SpiceEndpoint
    let observeSeconds: UInt64?
    let exerciseInput: Bool
}

private actor ProbeObservations {
    private var frames = 0
    private var cursors = 0
    private var keyboardEvents = 0
    private var motionAcknowledgements = 0

    func record(_ event: SpiceSessionEvent) {
        switch event {
        case .frame:
            frames += 1
        case .cursor:
            cursors += 1
        case .keyboardModifiers:
            keyboardEvents += 1
        case .mouseMotionAcknowledged:
            motionAcknowledgements += 1
        default:
            break
        }
    }

    func summary() -> ProbeObservationSummary {
        ProbeObservationSummary(
            frames: frames,
            cursors: cursors,
            keyboardEvents: keyboardEvents,
            motionAcknowledgements: motionAcknowledgements
        )
    }
}

private struct ProbeObservationSummary {
    let frames: Int
    let cursors: Int
    let keyboardEvents: Int
    let motionAcknowledgements: Int
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case missingObservation(String)

    var description: String {
        switch self {
        case .usage:
            "usage: spice-probe HOST PORT [--tls|--tls-insecure-for-testing-only] "
                + "[--observe-seconds N] [--exercise-input]; "
                + "password is read from SPICE_PASSWORD"
        case let .missingObservation(name):
            "missing required live observation: \(name)"
        }
    }
}
