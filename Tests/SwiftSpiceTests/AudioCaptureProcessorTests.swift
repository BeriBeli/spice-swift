import AVFAudio
import Foundation
import Testing
@testable import SwiftSpice

@Suite("Bounded audio capture conversion")
struct AudioCaptureProcessorTests {
    @Test(
        "tap callbacks at and above the requested size are split without losing PCM",
        arguments: [AVAudioFrameCount(1_024), 1_025, 2_051]
    )
    func oversizedTapCallbacksRemainBitExact(frameCount: AVAudioFrameCount) throws {
        let fixture = try CaptureProcessorFixture(frameCount: frameCount)
        let timestamp: UInt32 = 10_000

        fixture.processor.capture(fixture.input, timestamp: timestamp)
        let drain = fixture.processor.drain()

        let expectedPasses = Int((frameCount + 1_023) / 1_024)
        #expect(drain.failure == nil)
        #expect(drain.droppedBytes == 0)
        #expect(drain.packets.count == expectedPasses)
        #expect(drain.packets.map(\.timestamp) == (0 ..< expectedPasses).map {
            timestamp &+ UInt32(($0 * 1_024 * 1_000) / 8_000)
        })
        #expect(drain.packets.reduce(into: Data()) { result, packet in
            result.append(packet.data)
        } == fixture.expectedBytes)

        let diagnostics = fixture.processor.diagnostics()
        #expect(diagnostics.maximumInputFrames == 1_024)
        #expect(diagnostics.inputCallbacks == 1)
        #expect(diagnostics.inputFrames == UInt64(frameCount))
        #expect(diagnostics.splitInputCallbacks == (frameCount > 1_024 ? 1 : 0))
        #expect(diagnostics.conversionPasses == UInt64(expectedPasses))
        #expect(diagnostics.conversionFailures == 0)
        #expect(diagnostics.convertedFrames == UInt64(frameCount))
        #expect(diagnostics.inputChunkBufferAllocations == 1)
        #expect(diagnostics.outputBufferAllocations == 1)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        expectRealtimeRingCountersRemainZero(diagnostics.ring)
        #expect(diagnostics.ring.queuedBytes == 0)
        #expect(diagnostics.ring.queuedSlots == 0)
        #expect(diagnostics.ring.retainedSlots == 0)
    }

    @Test("multiple oversized callbacks preserve packet order across the sender boundary")
    func multipleOversizedCallbacksRemainFIFO() throws {
        let first = try CaptureProcessorFixture(frameCount: 2_051)
        let secondInput = try makePCMInput(
            format: first.format,
            frameCount: 1_025,
            seed: 0xa7
        )

        first.processor.capture(first.input, timestamp: 1_000)
        first.processor.capture(secondInput.buffer, timestamp: 2_000)
        let drain = first.processor.drain()

        #expect(drain.failure == nil)
        #expect(drain.droppedBytes == 0)
        #expect(drain.packets.map(\.timestamp) == [1_000, 1_128, 1_256, 2_000, 2_128])
        let expected = first.expectedBytes + secondInput.bytes
        #expect(drain.packets.reduce(into: Data()) { result, packet in
            result.append(packet.data)
        } == expected)
        let diagnostics = first.processor.diagnostics()
        #expect(diagnostics.inputCallbacks == 2)
        #expect(diagnostics.inputFrames == 3_076)
        #expect(diagnostics.splitInputCallbacks == 2)
        #expect(diagnostics.conversionPasses == 5)
        #expect(diagnostics.conversionFailures == 0)
        #expect(diagnostics.convertedFrames == 3_076)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        expectRealtimeRingCountersRemainZero(diagnostics.ring)
    }

    @Test("a malformed callback fails atomically and does not poison the next callback")
    func mismatchedInputFormatFailsWithoutPartialPublication() throws {
        let fixture = try CaptureProcessorFixture(frameCount: 1_024)
        let mismatchedFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 2,
            interleaved: true
        ))
        let mismatched = try makePCMInput(
            format: mismatchedFormat,
            frameCount: 1_025,
            seed: 0xdd
        )

        fixture.processor.capture(mismatched.buffer, timestamp: 500)
        let failed = fixture.processor.drain()
        #expect(failed.packets.isEmpty)
        #expect(failed.droppedBytes == 0)
        #expect(failed.failure == "capture input format changed while the tap was active")
        var diagnostics = fixture.processor.diagnostics()
        #expect(diagnostics.inputCallbacks == 1)
        #expect(diagnostics.inputFrames == 1_025)
        #expect(diagnostics.splitInputCallbacks == 1)
        #expect(diagnostics.conversionPasses == 0)
        #expect(diagnostics.conversionFailures == 1)
        #expect(diagnostics.convertedFrames == 0)
        #expect(diagnostics.ring.queuedBytes == 0)
        #expect(diagnostics.ring.retainedSlots == 0)

        fixture.processor.capture(fixture.input, timestamp: 1_000)
        let recovered = fixture.processor.drain()
        #expect(recovered.failure == nil)
        #expect(recovered.packets == [RecordedAudioPacket(
            timestamp: 1_000,
            data: fixture.expectedBytes
        )])
        diagnostics = fixture.processor.diagnostics()
        #expect(diagnostics.inputCallbacks == 2)
        #expect(diagnostics.conversionPasses == 1)
        #expect(diagnostics.conversionFailures == 1)
        #expect(diagnostics.convertedFrames == 1_024)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        expectRealtimeRingCountersRemainZero(diagnostics.ring)
    }

    @Test("non-interleaved device buffers split every AudioBufferList plane bit-exactly")
    func planarFloat32DeviceBufferMatchesOneShotConversion() throws {
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 2,
            interleaved: false
        ))
        let outputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8_000,
            channels: 2,
            interleaved: true
        ))
        let frameCount: AVAudioFrameCount = 2_051
        let input = try makePlanarFloat32Input(format: inputFormat, frameCount: frameCount)
        let expected = try referenceConversion(
            input: input,
            outputFormat: outputFormat
        )
        let converter = try #require(AVAudioConverter(
            from: inputFormat,
            to: outputFormat
        ))
        let processor = try #require(AudioCaptureProcessor(
            converter: converter,
            outputFormat: outputFormat,
            inputSampleRate: inputFormat.sampleRate,
            maximumInputFrames: 1_024,
            ringCapacity: AudioPacketRingCapacity(
                capacityBytes: expected.count * 2,
                capacitySlots: 8
            )
        ))

        processor.capture(input, timestamp: 3_000)
        let drain = processor.drain()

        #expect(drain.failure == nil)
        #expect(drain.droppedBytes == 0)
        #expect(drain.packets.map(\.timestamp) == [3_000, 3_128, 3_256])
        #expect(drain.packets.reduce(into: Data()) { result, packet in
            result.append(packet.data)
        } == expected)
        let diagnostics = processor.diagnostics()
        #expect(diagnostics.inputCallbacks == 1)
        #expect(diagnostics.inputFrames == UInt64(frameCount))
        #expect(diagnostics.splitInputCallbacks == 1)
        #expect(diagnostics.conversionPasses == 3)
        #expect(diagnostics.conversionFailures == 0)
        #expect(diagnostics.convertedFrames == UInt64(frameCount))
        #expect(diagnostics.inputChunkBufferAllocations == 1)
        #expect(diagnostics.outputBufferAllocations == 1)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        expectRealtimeRingCountersRemainZero(diagnostics.ring)
    }

    @Test("capture teardown discards queued and late callback ownership exactly once")
    func finishModelsCancellationWithoutLeakingSlots() throws {
        let fixture = try CaptureProcessorFixture(frameCount: 2_051)
        fixture.processor.capture(fixture.input, timestamp: .max - 100)
        #expect(fixture.processor.diagnostics().ring.retainedSlots == 3)

        fixture.processor.finish()
        fixture.processor.finish()
        fixture.processor.capture(fixture.input, timestamp: 42)

        #expect(fixture.processor.drain() == RecordCaptureDrain(
            packets: [],
            droppedBytes: 0,
            failure: nil
        ))
        let diagnostics = fixture.processor.diagnostics()
        #expect(diagnostics.ring.isClosed)
        #expect(diagnostics.ring.closeCount == 1)
        #expect(diagnostics.ring.queuedBytes == 0)
        #expect(diagnostics.ring.queuedSlots == 0)
        #expect(diagnostics.ring.retainedSlots == 0)
        #expect(diagnostics.ring.enqueuedPackets == 3)
        #expect(diagnostics.inputCallbacks == 2)
        #expect(diagnostics.conversionFailures == 0)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        expectRealtimeRingCountersRemainZero(diagnostics.ring)
    }
}

private struct CaptureProcessorFixture {
    let format: AVAudioFormat
    let input: AVAudioPCMBuffer
    let expectedBytes: Data
    let processor: AudioCaptureProcessor

    init(frameCount: AVAudioFrameCount) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8_000,
            channels: 2,
            interleaved: true
        ))
        let converter = try #require(AVAudioConverter(from: format, to: format))
        let input = try makePCMInput(format: format, frameCount: frameCount, seed: 0x31)
        let processor = try #require(AudioCaptureProcessor(
            converter: converter,
            outputFormat: format,
            inputSampleRate: format.sampleRate,
            maximumInputFrames: 1_024,
            ringCapacity: AudioPacketRingCapacity(
                capacityBytes: max(input.bytes.count * 2, 16_384),
                capacitySlots: 16
            )
        ))
        self.format = format
        self.input = input.buffer
        expectedBytes = input.bytes
        self.processor = processor
    }
}

private func makePCMInput(
    format: AVAudioFormat,
    frameCount: AVAudioFrameCount,
    seed: UInt8
) throws -> (buffer: AVAudioPCMBuffer, bytes: Data) {
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
    let byteCount = Int(frameCount) * bytesPerFrame
    let bytes = Data((0 ..< byteCount).map { index in
        seed &+ UInt8(truncatingIfNeeded: index &* 29 &+ index / 257)
    })
    let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
    let destination = try #require(audioBuffer.mData)
    try bytes.withUnsafeBytes { source in
        let sourceBaseAddress = try #require(source.baseAddress)
        destination.copyMemory(from: sourceBaseAddress, byteCount: byteCount)
    }
    return (buffer, bytes)
}

private func makePlanarFloat32Input(
    format: AVAudioFormat,
    frameCount: AVAudioFrameCount
) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    let channels = try #require(buffer.floatChannelData)
    for channel in 0 ..< Int(format.channelCount) {
        for frame in 0 ..< Int(frameCount) {
            let centered = Float((frame &* 13 &+ channel &* 7) % 31) - 15
            channels[channel][frame] = centered / 20
        }
    }
    return buffer
}

private func referenceConversion(
    input: AVAudioPCMBuffer,
    outputFormat: AVAudioFormat
) throws -> Data {
    let converter = try #require(AVAudioConverter(from: input.format, to: outputFormat))
    let output = try #require(AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: input.frameLength + 8
    ))
    let provider = ReferenceConverterInputProvider(input)
    var conversionError: NSError?
    let status = converter.convert(
        to: output,
        error: &conversionError,
        withInputFrom: { _, inputStatus in
            guard let buffer = provider.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
    )
    guard status != .error else {
        throw CaptureFixtureError.conversion(
            conversionError.map(String.init(describing:)) ?? "unknown"
        )
    }
    let byteCount = Int(output.frameLength)
        * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
    let audioBuffer = output.audioBufferList.pointee.mBuffers
    let source = try #require(audioBuffer.mData)
    return Data(bytes: source, count: byteCount)
}

private final class ReferenceConverterInputProvider: @unchecked Sendable {
    private var input: AVAudioPCMBuffer?

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func take() -> AVAudioPCMBuffer? {
        defer { input = nil }
        return input
    }
}

private enum CaptureFixtureError: Error {
    case conversion(String)
}

private func expectRealtimeRingCountersRemainZero(_ diagnostics: AudioPacketRingDiagnostics) {
    #expect(diagnostics.linearMovementBytes == 0)
    #expect(diagnostics.callbackDynamicAllocations == 0)
    #expect(diagnostics.perPacketStorageAllocations == 0)
}
