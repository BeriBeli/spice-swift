@preconcurrency import AVFAudio
import Dispatch
import Foundation

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
        precondition(maximumQueuedMilliseconds > 0)
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
        let maximumBytes = try Self.maximumBytes(
            configuration: configuration,
            milliseconds: maximumQueuedMilliseconds
        )
        let processor = AudioCaptureProcessor(
            converter: converter,
            outputFormat: outputFormat,
            maximumBytes: maximumBytes
        )
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
        for await _ in processor.signals {
            guard !Task.isCancelled else {
                break
            }
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

    private nonisolated static func maximumBytes(
        configuration: SpiceRecordConfiguration,
        milliseconds: UInt32
    ) throws(SpiceAudioCaptureSourceError) -> Int {
        let bytesPerSecond = UInt64(configuration.sampleRate)
            * UInt64(configuration.channels)
            * UInt64(MemoryLayout<Int16>.size)
        let bytes = (bytesPerSecond * UInt64(milliseconds) + 999) / 1_000
        guard let value = Int(exactly: bytes), value > 0 else {
            throw .invalidConfiguration("capture buffer size overflow")
        }
        return value
    }

    private nonisolated static func milliseconds(
        bytes: Int,
        configuration: SpiceRecordConfiguration
    ) -> UInt32 {
        let bytesPerSecond = UInt64(configuration.sampleRate)
            * UInt64(configuration.channels)
            * UInt64(MemoryLayout<Int16>.size)
        guard bytesPerSecond > 0 else {
            return 0
        }
        let value = (UInt64(bytes) * 1_000 + bytesPerSecond - 1) / bytesPerSecond
        return UInt32(min(value, UInt64(UInt32.max)))
    }

    private nonisolated static func timestamp() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}

/// AVAudioEngine invokes one tap serially, so the converter has one caller.
/// The queue itself is mutex-protected for the async drain side.
private final class AudioCaptureProcessor: @unchecked Sendable {
    let signals: AsyncStream<Void>

    private let signalContinuation: AsyncStream<Void>.Continuation
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let buffer: RecordCaptureBuffer

    init(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        maximumBytes: Int
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        buffer = RecordCaptureBuffer(maximumBytes: maximumBytes)
        let pipe = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        signals = pipe.stream
        signalContinuation = pipe.continuation
    }

    func capture(_ input: AVAudioPCMBuffer, timestamp: UInt32) {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = Double(input.frameLength) * ratio
        guard estimatedFrames.isFinite,
              estimatedFrames >= 0,
              estimatedFrames < Double(AVAudioFrameCount.max),
              let output = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(estimatedFrames.rounded(.up)) + 8
              ) else {
            fail("converted frame count is invalid")
            return
        }

        let inputProvider = ConverterInputProvider(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            guard let input = inputProvider.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return input
        }
        if status == .error {
            fail(conversionError.map(String.init(describing:)) ?? "unknown converter error")
            return
        }
        guard output.frameLength > 0 else {
            return
        }
        let byteCount = Int(output.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard byteCount > 0,
              byteCount <= Int(audioBuffer.mDataByteSize),
              let pointer = audioBuffer.mData else {
            fail("converter produced invalid PCM storage")
            return
        }
        buffer.push(RecordedAudioPacket(
            timestamp: timestamp,
            data: Data(bytes: pointer, count: byteCount)
        ))
        signalContinuation.yield()
    }

    func drain() -> RecordCaptureDrain {
        buffer.drain()
    }

    func finish() {
        signalContinuation.finish()
    }

    private func fail(_ reason: String) {
        buffer.fail(reason)
        signalContinuation.yield()
    }
}

/// AVAudioConverter calls its input block synchronously for this conversion.
private final class ConverterInputProvider: @unchecked Sendable {
    private var input: AVAudioPCMBuffer?

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func take() -> AVAudioPCMBuffer? {
        defer { input = nil }
        return input
    }
}
