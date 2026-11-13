import Darwin
import Foundation
import SwiftSpice

struct LatencyStatistics: Codable, Equatable {
    let count: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let maximumMilliseconds: Double?

    init(nanoseconds: [UInt64]) {
        let sorted = nanoseconds.sorted()
        let sampleCount = sorted.count
        count = sampleCount
        func percentile(_ fraction: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            return Double(sorted[max(0, Int(ceil(Double(sampleCount) * fraction)) - 1)]) / 1_000_000
        }
        p50Milliseconds = percentile(0.5)
        p95Milliseconds = percentile(0.95)
        maximumMilliseconds = sorted.last.map { Double($0) / 1_000_000 }
    }
}

struct InteractionStatistics: Codable {
    let attempted: Int
    let valid: Int
    let invalidReasons: [String: Int]
    let stages: [String: LatencyStatistics]
    let sendCompletionOverlapsDisplay: Int

    init(records: [SpiceInteractionTraceRecord]) {
        attempted = records.count
        let accepted = records.filter(\.valid)
        valid = accepted.count
        invalidReasons = records.filter { !$0.valid }.reduce(into: [:]) {
            $0[$1.invalidReason ?? "unknown", default: 0] += 1
        }
        typealias Field = KeyPath<SpiceInteractionTraceRecord, UInt64?>
        let intervals: [(String, Field, Field)] = [
            ("schedule_to_input", \.scheduledNs, \.hostInputNs),
            ("input_to_send", \.hostInputNs, \.sendStartedNs),
            ("send_call", \.sendStartedNs, \.sendCompletedNs),
            ("send_start_to_display_receive", \.sendStartedNs, \.displayReceiveNs),
            ("send_complete_to_display_receive", \.sendCompletedNs, \.displayReceiveNs),
            ("display_receive_to_surface_ready", \.displayReceiveNs, \.surfaceReadyNs),
            ("surface_ready_to_selection", \.surfaceReadyNs, \.selectionNs),
            ("selection_to_commit", \.selectionNs, \.metalCommitNs),
            ("commit_to_presented", \.metalCommitNs, \.presentedNs),
            ("surface_ready_to_presented", \.surfaceReadyNs, \.presentedNs),
            ("input_to_presented", \.hostInputNs, \.presentedNs),
            ("guest_handler_to_marker_draw", \.guestReceivedNs, \.guestMarkerDrawnNs),
        ]
        stages = Dictionary(
            uniqueKeysWithValues: intervals.map { name, start, end in
                let values = accepted.compactMap { record -> UInt64? in
                    guard let a = record[keyPath: start], let b = record[keyPath: end], b >= a
                    else { return nil }
                    return b - a
                }
                return (name, LatencyStatistics(nanoseconds: values))
            })
        sendCompletionOverlapsDisplay =
            accepted.filter {
                guard let send = $0.sendCompletedNs, let display = $0.displayReceiveNs else {
                    return false
                }
                return display < send
            }.count
    }
}

struct ProcessMeasurement {
    let nanoseconds = SpiceInteractionHostClock.nowNanoseconds()
    let cpuSeconds: Double
    let peakResidentBytes: Int64

    init() {
        var time = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
        cpuSeconds = Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        var usage = rusage()
        peakResidentBytes = getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : 0
    }
}

struct SessionBenchmarkReport: Encodable {
    let schemaVersion = 1
    #if DEBUG
        let buildConfiguration = "debug"
    #else
        let buildConfiguration = "release"
    #endif
    let runID: String
    let label: String
    let mode: String
    let status: String
    let failure: String?
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let processorCount = ProcessInfo.processInfo.processorCount
    let codecPolicy: String
    let tls: Bool
    let headless: Bool
    let presentationStatus: String
    let warmup: Int
    let requestedSamples: Int
    let intervalMilliseconds: Int
    let connectMilliseconds: Double?
    let measuredSeconds: Double
    let processCPUSeconds: Double
    let processPeakResidentBytesAtStart: Int64
    let processPeakResidentBytesAtEnd: Int64
    let desktopFrames: Int
    let desktopFramesPerSecond: Double
    let frameSizes: [String]
    let localBackingScale: Double?
    let localMaximumFramesPerSecond: Int?
    let interaction: InteractionStatistics
    let diagnosticsSinceConnect: DiagnosticReport
}

/// These are lifetime snapshots, including connection/readiness/warmup. Keeping
/// that scope explicit avoids subtracting cumulative histogram percentiles.
struct DiagnosticReport: Encodable {
    struct Timing: Encodable {
        let count: UInt64
        let approximateP95Milliseconds: Double?
        let maximumMilliseconds: Double?

        init(_ summary: SpiceTimingSummary) {
            count = summary.sampleCount
            approximateP95Milliseconds = summary.p95Milliseconds
            maximumMilliseconds = summary.maximumMilliseconds
        }
    }

    let counters: [String: UInt64]
    let gauges: [String: Int]
    let timings: [String: Timing]
    let lastCPUFallbackReason: String?

    init(_ snapshot: SpiceSessionDiagnostics) {
        lastCPUFallbackReason = snapshot.lastCPUFallbackReason?.rawValue
        counters = [
            "publisher_frames": snapshot.publisherEmittedFrames,
            "publisher_iosurface_frames": snapshot.publisherEmittedIOSurfaceFrames,
            "publisher_cpu_frames": snapshot.publisherEmittedCPUOnlyFrames,
            "publisher_coalesces": snapshot.publisherPendingRevisionCoalesces,
            "full_frame_copy_bytes": snapshot.fullFrameCopyBytes,
            "partial_frame_copy_bytes": snapshot.partialFrameCopyBytes,
            "direct_iosurface_write_bytes": snapshot.directIOSurfaceWriteBytes,
            "cpu_materializations": snapshot.cpuMaterializations,
            "cpu_materialization_bytes": snapshot.cpuMaterializationBytes,
            "gpu_copy_bytes": snapshot.gpuCopyBytes,
            "gpu_errors": snapshot.gpuErrors,
            "mjpeg_decoded_frames": snapshot.mjpegDecodedFrames,
            "mjpeg_iosurface_frames": snapshot.mjpegIOSurfaceFrames,
            "mjpeg_data_fallbacks": snapshot.mjpegDataFallbacks,
            "video_hardware_sessions": snapshot.videoHardwareSessions,
            "video_software_sessions": snapshot.videoSoftwareSessions,
            "video_decoded_frames": snapshot.videoDecodedFrames,
            "video_dropped_frames": snapshot.videoDroppedFrames,
            "native_video_frames": snapshot.nativeVideoFrames,
            "advanced_cpu_fallback_frames": snapshot.advancedCPUFallbackFrames,
            "metal_presented_frames": snapshot.metalPresentedFrames,
            "metal_presentation_errors": snapshot.metalPresentationErrors,
            "metal_command_buffers_committed": snapshot.metalCommandBuffersCommitted,
            "metal_command_creation_failures": snapshot.metalCommandCreationFailures,
            "cpu_fallback_frames": snapshot.cpuFallbackFrames,
            "metal_unavailable_fallback_frames": snapshot.metalUnavailableFallbackFrames,
            "missing_iosurface_fallback_frames": snapshot.missingIOSurfaceFallbackFrames,
            "dimension_mismatch_fallback_frames": snapshot.ioSurfaceDimensionMismatchFallbackFrames,
            "pixel_format_fallback_frames": snapshot.pixelFormatMismatchFallbackFrames,
            "texture_creation_fallback_frames": snapshot.textureCreationFailedFallbackFrames,
            "metal_command_failure_fallback_frames": snapshot.metalCommandFailureFallbackFrames,
            "metal_drawable_misses": snapshot.metalDrawableMisses,
            "metal_gpu_busy_skips": snapshot.metalGPUBusySkips,
        ]
        gauges = [
            "surface_allocated_bytes": snapshot.surfaceAllocatedBytes,
            "iosurface_allocated_bytes_process_wide": snapshot.totalIOSurfaceAllocatedBytes,
            "metal_allocated_bytes": Int(clamping: snapshot.currentMetalAllocatedSize),
        ]
        timings = [
            "display_receive_to_surface_ready": Timing(
                snapshot.publisherMessageReceiveToSurfaceReady),
            "surface_ready_to_submit": Timing(snapshot.publisherSurfaceReadyToSubmit),
            "publisher_scheduling": Timing(snapshot.publisherFlushSchedulingDelay),
            "publisher_snapshot": Timing(snapshot.publisherSnapshotDuration),
            "publisher_emit": Timing(snapshot.publisherEmitDuration),
            "ready_to_selection": Timing(snapshot.desktopReadyToDisplayLink),
            "view_to_commit": Timing(snapshot.viewUpdateToMetalCommit),
            "commit_to_completion": Timing(snapshot.metalCommitToCompletion),
            "request_to_presented": Timing(snapshot.metalRequestToPresented),
        ]
    }
}
