@preconcurrency import AVFAudio
import Dispatch
import Foundation
import Synchronization

public enum SpiceAudioCaptureSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case invalidConfiguration(String)
    case audioEngine(String)
    case conversion(String)
    case session(SpiceError)

    public var description: String {
        switch self {
        case .alreadyRunning:
            "audio capture source is already running"
        case let .invalidConfiguration(reason):
            "invalid record configuration: \(reason)"
        case let .audioEngine(reason):
            "audio capture engine failed: \(reason)"
        case let .conversion(reason):
            "audio conversion failed: \(reason)"
        case let .session(error):
            "record channel failed: \(error)"
        }
    }
}

public enum SpiceAudioCaptureSourceEvent: Sendable, Equatable {
    case started(SpiceRecordConfiguration)
    case stopped
    case overflowDropped(milliseconds: UInt32)
    case volumeChanged([UInt16])
    case muteChanged(Bool)
    case failed(SpiceAudioCaptureSourceError)
}

/// A bounded macOS microphone source for SPICE RAW signed 16-bit PCM.
///
/// The embedding app remains responsible for declaring microphone usage and
/// presenting any consent UI before starting this source.
public actor SpiceAudioCaptureSource {
    public nonisolated let events: AsyncStream<SpiceAudioCaptureSourceEvent>

    private let eventContinuation: AsyncStream<SpiceAudioCaptureSourceEvent>.Continuation
    private let maximumQueuedMilliseconds: UInt32
    private let engine = AVAudioEngine()
    private var eventTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var processor: AudioCaptureProcessor?
    private var configuration: SpiceRecordConfiguration?

    public init(maximumQueuedMilliseconds: UInt32 = 500) {
        self.maximumQueuedMilliseconds = maximumQueuedMilliseconds
        let pipe = AsyncStream.makeStream(
            of: SpiceAudioCaptureSourceEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        events = pipe.stream
        eventContinuation = pipe.continuation
    }

    deinit {
        eventTask?.cancel()
        sendTask?.cancel()
        eventContinuation.finish()
    }

    public func start(session: SpiceSession) throws(SpiceAudioCaptureSourceError) {
        guard eventTask == nil else {
            throw .alreadyRunning
        }
        eventTask = Task { [weak self] in
            await self?.consumeRecordEvents(from: session)
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        stopStream(emit: configuration != nil)
    }

    private func consumeRecordEvents(from session: SpiceSession) async {
        for await event in session.recordEvents {
            guard !Task.isCancelled else {
                break
            }
            do {
                switch event {
                case let .started(configuration):
                    try await startStream(configuration, session: session)
                case .stopped:
                    stopStream(emit: true)
                case let .volumeChanged(volume):
                    eventContinuation.yield(.volumeChanged(volume))
                case let .muteChanged(mute):
                    eventContinuation.yield(.muteChanged(mute))
                }
            } catch let error {
                eventContinuation.yield(.failed(error))
                stopStream(emit: configuration != nil)
            }
        }
    }

    private func startStream(
        _ configuration: SpiceRecordConfiguration,
        session: SpiceSession
    ) async throws(SpiceAudioCaptureSourceError) {
        guard configuration.format == .signed16LittleEndian,
              (1 ... 8).contains(configuration.channels),
              (8_000 ... 192_000).contains(configuration.sampleRate) else {
            throw .invalidConfiguration("unsupported format, channel count, or sample rate")
        }
        stopStream(emit: self.configuration != nil)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw .audioEngine("no usable default input device")
        }
        guard let outputFormat = Self.audioFormat(for: configuration),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw .invalidConfiguration("AVAudioConverter rejected the requested PCM format")
        }
        let ringCapacity = try Self.ringCapacity(
            configuration: configuration,
            maximumQueuedMilliseconds: maximumQueuedMilliseconds
        )
        guard let processor = AudioCaptureProcessor(
            converter: converter,
            outputFormat: outputFormat,
            inputSampleRate: inputFormat.sampleRate,
            maximumInputFrames: 1_024,
            ringCapacity: ringCapacity
        ) else {
            throw .audioEngine("unable to preallocate capture conversion buffers")
        }
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat
        ) { buffer, _ in
            processor.capture(buffer, timestamp: Self.timestamp())
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw .audioEngine(String(describing: error))
        }

        let startTimestamp = Self.timestamp()
        do {
            try await session.beginRecording(timestamp: startTimestamp)
        } catch let error {
            input.removeTap(onBus: 0)
            engine.stop()
            throw .session(error)
        }

        self.processor = processor
        self.configuration = configuration
        sendTask = Task { [weak self] in
            await self?.sendCapturedAudio(
                from: processor,
                configuration: configuration,
                session: session
            )
        }
        eventContinuation.yield(.started(configuration))
    }

    private func sendCapturedAudio(
        from processor: AudioCaptureProcessor,
        configuration: SpiceRecordConfiguration,
        session: SpiceSession
    ) async {
        while !Task.isCancelled {
            let drain = processor.drain()
            if let failure = drain.failure {
                eventContinuation.yield(.failed(.conversion(failure)))
                stopStream(emit: self.configuration != nil)
                return
            }
            if drain.droppedBytes > 0 {
                eventContinuation.yield(.overflowDropped(milliseconds: Self.milliseconds(
                    bytes: drain.droppedBytes,
                    configuration: configuration
                )))
            }
            for packet in drain.packets {
                do {
                    try await session.sendRecordedAudio(
                        timestamp: packet.timestamp,
                        pcm: packet.data
                    )
                } catch let error {
                    eventContinuation.yield(.failed(.session(error)))
                    stopStream(emit: self.configuration != nil)
                    return
                }
            }
            do {
                try await ContinuousClock().sleep(for: .milliseconds(2))
            } catch {
                break
            }
        }
    }

    private func stopStream(emit: Bool) {
        sendTask?.cancel()
        sendTask = nil
        if configuration != nil {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        processor?.finish()
        processor = nil
        configuration = nil
        if emit {
            eventContinuation.yield(.stopped)
        }
    }

    private nonisolated static func audioFormat(
        for configuration: SpiceRecordConfiguration
    ) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(configuration.sampleRate),
            channels: AVAudioChannelCount(configuration.channels),
            interleaved: true
        )
    }

    package nonisolated static func ringCapacity(
        configuration: SpiceRecordConfiguration,
        maximumQueuedMilliseconds: UInt32
    ) throws(SpiceAudioCaptureSourceError) -> AudioPacketRingCapacity {
        guard configuration.sampleRate > 0,
              configuration.channels > 0,
              maximumQueuedMilliseconds > 0 else {
            throw .invalidConfiguration("capture ring dimensions must be positive")
        }
        let (frameMilliseconds, frameOverflow) = UInt64(configuration.sampleRate)
            .multipliedReportingOverflow(by: UInt64(maximumQueuedMilliseconds))
        let (roundedFrameMilliseconds, roundingOverflow) = frameMilliseconds
            .addingReportingOverflow(999)
        guard !frameOverflow, !roundingOverflow else {
            throw .invalidConfiguration("capture ring frame capacity overflow")
        }
        let frames = roundedFrameMilliseconds / 1_000
        let (bytesPerFrame, frameSizeOverflow) = configuration.channels
            .multipliedReportingOverflow(by: MemoryLayout<Int16>.size)
        guard !frameSizeOverflow, bytesPerFrame > 0 else {
            throw .invalidConfiguration("capture ring frame size overflow")
        }
        let (bytes, byteOverflow) = frames.multipliedReportingOverflow(
            by: UInt64(bytesPerFrame)
        )
        guard !byteOverflow, let capacityBytes = Int(exactly: bytes) else {
            throw .invalidConfiguration("capture ring byte capacity overflow")
        }
        do {
            // Every nonempty converted packet contains at least one output
            // frame. Reserving one slot per frame therefore guarantees packet
            // metadata cannot exhaust before the independent payload-byte
            // budget, regardless of tap callback or conversion chunk shape.
            let capacitySlots = try AudioPacketRingCapacity.slotCount(
                capacityBytes: capacityBytes,
                minimumPacketBytes: bytesPerFrame
            )
            return try AudioPacketRingAllocationLimits.validate(
                capacityBytes: capacityBytes,
                capacitySlots: capacitySlots
            )
        } catch {
            throw .invalidConfiguration("capture ring allocation exceeds resource limits")
        }
    }

    private nonisolated static func milliseconds(
        bytes: Int,
        configuration: SpiceRecordConfiguration
    ) -> UInt32 {
        let (sampleChannels, channelOverflow) = UInt64(configuration.sampleRate)
            .multipliedReportingOverflow(by: UInt64(configuration.channels))
        let (bytesPerSecond, sampleSizeOverflow) = sampleChannels
            .multipliedReportingOverflow(by: UInt64(MemoryLayout<Int16>.size))
        guard !channelOverflow, !sampleSizeOverflow else {
            return .max
        }
        guard bytesPerSecond > 0 else {
            return 0
        }
        let (scaledBytes, scaleOverflow) = UInt64(bytes).multipliedReportingOverflow(by: 1_000)
        let (roundedBytes, roundingOverflow) = scaledBytes.addingReportingOverflow(
            bytesPerSecond - 1
        )
        guard !scaleOverflow, !roundingOverflow else {
            return .max
        }
        let value = roundedBytes / bytesPerSecond
        return UInt32(min(value, UInt64(UInt32.max)))
    }

    private nonisolated static func timestamp() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    package func ringDiagnostics() -> AudioPacketRingDiagnostics? {
        processor?.diagnostics().ring
    }
}

package struct AudioCaptureProcessorDiagnostics: Sendable, Equatable {
    package let maximumInputFrames: AVAudioFrameCount
    package let inputCallbacks: UInt64
    package let inputFrames: UInt64
    package let splitInputCallbacks: UInt64
    package let conversionPasses: UInt64
    package let conversionFailures: UInt64
    package let convertedFrames: UInt64
    package let inputChunkBufferAllocations: UInt64
    package let outputBufferAllocations: UInt64
    package let callbackDynamicAllocations: UInt64
    package let ring: AudioPacketRingDiagnostics
}

/// AVAudioEngine invokes one tap serially, so the converter has one caller.
/// The queue itself is mutex-protected for the async drain side.
package final class AudioCaptureProcessor: @unchecked Sendable {
    private struct DiagnosticState: Sendable {
        var inputCallbacks: UInt64 = 0
        var inputFrames: UInt64 = 0
        var splitInputCallbacks: UInt64 = 0
        var conversionPasses: UInt64 = 0
        var conversionFailures: UInt64 = 0
        var convertedFrames: UInt64 = 0
    }

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let inputChunkBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let inputSampleRate: Double
    private let maximumInputFrames: AVAudioFrameCount
    private let inputProvider: ConverterInputProvider
    private let converterInputBlock: AVAudioConverterInputBlock
    private let buffer: RecordCaptureBuffer
    private let diagnosticState = Mutex(DiagnosticState())

    package init?(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        inputSampleRate: Double,
        maximumInputFrames: AVAudioFrameCount,
        ringCapacity: AudioPacketRingCapacity
    ) {
        let inputFormat = converter.inputFormat
        let ratio = outputFormat.sampleRate / inputSampleRate
        let estimatedFrames = Double(maximumInputFrames) * ratio
        guard ratio.isFinite,
              ratio > 0,
              inputSampleRate.isFinite,
              inputSampleRate > 0,
              inputFormat.sampleRate == inputSampleRate,
              converter.outputFormat == outputFormat,
              outputFormat.isInterleaved,
              maximumInputFrames > 0,
              inputFormat.streamDescription.pointee.mBytesPerFrame > 0,
              estimatedFrames.isFinite,
              estimatedFrames >= 0,
              estimatedFrames < Double(AVAudioFrameCount.max) - 8,
              let inputChunkBuffer = AVAudioPCMBuffer(
                  pcmFormat: inputFormat,
                  frameCapacity: maximumInputFrames
              ),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(estimatedFrames.rounded(.up)) + 8
              ) else {
            return nil
        }
        let provider = ConverterInputProvider()
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.inputChunkBuffer = inputChunkBuffer
        self.outputBuffer = outputBuffer
        self.inputSampleRate = inputSampleRate
        self.maximumInputFrames = maximumInputFrames
        inputProvider = provider
        converterInputBlock = { _, status in
            guard let input = provider.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return input
        }
        buffer = RecordCaptureBuffer(
            maximumBytes: ringCapacity.capacityBytes,
            maximumPackets: ringCapacity.capacitySlots
        )
    }

    package func capture(
        _ input: AVAudioPCMBuffer,
        timestamp: UInt32,
        failureForTesting: AudioCaptureProcessorFailure? = nil
    ) {
        diagnosticState.withLock { state in
            Self.add(&state.inputCallbacks, 1)
            Self.add(&state.inputFrames, Int(input.frameLength))
            if input.frameLength > maximumInputFrames {
                Self.add(&state.splitInputCallbacks, 1)
            }
        }
        if let failureForTesting {
            recordFailure(failureForTesting)
            return
        }
        guard input.frameLength > 0 else { return }
        guard input.format == inputFormat else {
            recordFailure(.inputFormatChanged)
            return
        }
        guard validateInputStorage(input) else {
            recordFailure(.invalidInputStorage)
            return
        }

        var frameOffset: AVAudioFrameCount = 0
        while frameOffset < input.frameLength {
            let frameCount = min(maximumInputFrames, input.frameLength - frameOffset)
            guard copyInputChunk(
                from: input,
                frameOffset: frameOffset,
                frameCount: frameCount
            ) else {
                recordFailure(.invalidInputStorage)
                return
            }
            guard convertInputChunk(
                timestamp: Self.chunkTimestamp(
                    base: timestamp,
                    inputFrameOffset: frameOffset,
                    inputSampleRate: inputSampleRate
                )
            ) else { return }
            frameOffset += frameCount
        }
    }

    private func convertInputChunk(timestamp: UInt32) -> Bool {
        outputBuffer.frameLength = 0
        inputProvider.offer(inputChunkBuffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError,
            withInputFrom: converterInputBlock
        )
        inputProvider.clear()
        if status == .error {
            recordFailure(.converter(code: conversionError?.code))
            return false
        }
        diagnosticState.withLock { state in
            Self.add(&state.conversionPasses, 1)
            Self.add(&state.convertedFrames, Int(outputBuffer.frameLength))
        }
        guard outputBuffer.frameLength > 0 else {
            return true
        }
        let (byteCount, byteCountOverflow) = Int(outputBuffer.frameLength)
            .multipliedReportingOverflow(
                by: Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
            )
        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard !byteCountOverflow,
              byteCount > 0,
              byteCount <= Int(audioBuffer.mDataByteSize),
              let pointer = audioBuffer.mData else {
            recordFailure(.invalidOutputStorage)
            return false
        }
        _ = buffer.push(
            timestamp: timestamp,
            bytes: UnsafeRawBufferPointer(start: pointer, count: byteCount)
        )
        return true
    }

    package func drain() -> RecordCaptureDrain {
        buffer.drain()
    }

    package func finish() {
        buffer.close()
    }

    package func diagnostics() -> AudioCaptureProcessorDiagnostics {
        let ring = buffer.diagnostics()
        return diagnosticState.withLock { state in
            AudioCaptureProcessorDiagnostics(
                maximumInputFrames: maximumInputFrames,
                inputCallbacks: state.inputCallbacks,
                inputFrames: state.inputFrames,
                splitInputCallbacks: state.splitInputCallbacks,
                conversionPasses: state.conversionPasses,
                conversionFailures: state.conversionFailures,
                convertedFrames: state.convertedFrames,
                inputChunkBufferAllocations: 1,
                outputBufferAllocations: 1,
                callbackDynamicAllocations: 0,
                ring: ring
            )
        }
    }

    package static func chunkTimestamp(
        base: UInt32,
        inputFrameOffset: AVAudioFrameCount,
        inputSampleRate: Double
    ) -> UInt32 {
        guard inputSampleRate.isFinite, inputSampleRate > 0 else { return base }
        let milliseconds = floor(Double(inputFrameOffset) * 1_000 / inputSampleRate)
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(UInt64.max) else { return base }
        return base &+ UInt32(truncatingIfNeeded: UInt64(milliseconds))
    }

    private func copyInputChunk(
        from input: AVAudioPCMBuffer,
        frameOffset: AVAudioFrameCount,
        frameCount: AVAudioFrameCount
    ) -> Bool {
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        let (sourceByteOffset, offsetOverflow) = Int(frameOffset)
            .multipliedReportingOverflow(by: bytesPerFrame)
        let (byteCount, byteCountOverflow) = Int(frameCount)
            .multipliedReportingOverflow(by: bytesPerFrame)
        guard !offsetOverflow, !byteCountOverflow, byteCount > 0 else { return false }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        inputChunkBuffer.frameLength = frameCount
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            inputChunkBuffer.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            let destination = destinationBuffers[index]
            let (requiredSourceBytes, sourceOverflow) = sourceByteOffset
                .addingReportingOverflow(byteCount)
            guard !sourceOverflow,
                  requiredSourceBytes <= Int(source.mDataByteSize),
                  byteCount <= Int(destination.mDataByteSize),
                  let sourcePointer = source.mData,
                  let destinationPointer = destination.mData else {
                return false
            }
            destinationPointer.copyMemory(
                from: sourcePointer.advanced(by: sourceByteOffset),
                byteCount: byteCount
            )
        }
        return true
    }

    private func validateInputStorage(_ input: AVAudioPCMBuffer) -> Bool {
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        let (requiredBytes, overflow) = Int(input.frameLength)
            .multipliedReportingOverflow(by: bytesPerFrame)
        guard !overflow, requiredBytes > 0 else { return false }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            inputChunkBuffer.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        return sourceBuffers.allSatisfy { source in
            requiredBytes <= Int(source.mDataByteSize) && source.mData != nil
        }
    }

    private func recordFailure(_ failure: AudioCaptureProcessorFailure) {
        diagnosticState.withLock { state in
            Self.add(&state.conversionFailures, 1)
        }
        buffer.fail(failure)
    }

    private static func add(_ value: inout UInt64, _ amount: Int) {
        guard amount > 0 else { return }
        let increment = UInt64(amount)
        value = value > UInt64.max - increment ? UInt64.max : value + increment
    }
}

/// AVAudioConverter calls its input block synchronously for this conversion.
private final class ConverterInputProvider: @unchecked Sendable {
    private var input: AVAudioPCMBuffer?

    func offer(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func take() -> AVAudioPCMBuffer? {
        defer { input = nil }
        return input
    }

    func clear() {
        input = nil
    }
}
