import CoreGraphics
import Foundation
import ImageIO
import SwiftSpice
import UniformTypeIdentifiers

private enum FixtureFailure: Error { case transferFailed, noFrame, imageEncodingFailed }

private actor FixtureTransferObservation {
    enum Phase: String { case connecting, startingAgent, openingFile, waitingForGuest, sending }
    private var phase = Phase.connecting
    private var sentBytes: UInt64 = 0
    func set(_ phase: Phase) { self.phase = phase }
    func sent(_ bytes: UInt64) { phase = .sending; sentBytes = bytes }
    var summary: String { "stage=\(phase.rawValue) sent_bytes=\(sentBytes)" }
}

func fixtureTransferFailureCategory(_ error: any Error) -> String {
    switch error {
    case SessionBenchmarkError.timedOut: "timeout"
    case let error as SpiceFileTransferError:
        switch error {
        case .agentManagerNotRunning: "manager_not_running"
        case .agentUnavailable: "agent_unavailable"
        case .disabledByGuest: "disabled_by_guest"
        case .tooManyConcurrentTransfers: "transfer_limit"
        case .invalidFile: "invalid_file"
        case .fileTooLarge: "file_too_large"
        case .invalidAgentResponse: "guest_response"
        case .localReadFailed: "local_read"
        case .transport: "transport"
        }
    case is CancellationError: "cancelled"
    default: "other"
    }
}

func transferFixture(_ source: URL, configuration: BenchmarkConfiguration) async -> Bool {
    let session = SpiceSession()
    let manager = SpiceAgentManager(
        automaticallySynchronizesPasteboard: false, pasteboardSynchronizationEnabled: false
    )
    let success: Bool
    let observation = FixtureTransferObservation()
    do {
        try await withBenchmarkTimeout(seconds: configuration.timeoutSeconds) {
            _ = try await session.connect(
                endpoint: configuration.endpoint,
                credentials: SpiceCredentials(password: configuration.password)
            )
            await observation.set(.startingAgent)
            try await manager.start(session: session)
            await observation.set(.openingFile)
            let id = try await manager.sendFile(at: source, name: source.lastPathComponent)
            await observation.set(.waitingForGuest)
            await SessionBenchmark.progress("fixture_transfer_submitted")
            for await event in manager.fileTransferEvents {
                switch event {
                case let .progress(eventID, sentBytes, _) where eventID == id:
                    await observation.sent(sentBytes)
                case let .completed(eventID) where eventID == id: return
                case let .failed(eventID, error) where eventID == nil || eventID == id:
                    throw error
                case let .cancelled(eventID) where eventID == id: throw CancellationError()
                default: break
                }
            }
            throw FixtureFailure.transferFailed
        }
        await SessionBenchmark.progress("fixture_transfer_completed")
        success = true
    } catch {
        await SessionBenchmark.progress(
            "fixture_transfer_failed category=\(fixtureTransferFailureCategory(error)) "
                + observation.summary
        )
        success = false
    }
    await manager.stop()
    await session.disconnect()
    return success
}

/// Explicit observation export; called only after measurement and diagnostics end.
func writeBenchmarkSnapshot(_ frame: SpiceFrame?, to destination: URL) throws {
    guard let frame else { throw FixtureFailure.noFrame }
    let pixels = frame.pixels
    guard let provider = CGDataProvider(data: pixels as CFData),
          let image = CGImage(
            width: frame.width, height: frame.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
          )
    else { throw FixtureFailure.imageEncodingFailed }
    let data = NSMutableData()
    guard let writer = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ) else { throw FixtureFailure.imageEncodingFailed }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { throw FixtureFailure.imageEncodingFailed }
    try (data as Data).write(to: destination, options: .atomic)
}
