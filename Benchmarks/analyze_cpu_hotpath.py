#!/usr/bin/env python3
"""Audit and recompute the checked-in same-harness CPU hot-path evidence."""

from __future__ import annotations

import argparse
import json
import re
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


METRICS = (
    ("cpu_nanoseconds_per_frame", "cpuPerFrame"),
    ("cpu_nanoseconds_per_command", "cpuPerCommand"),
    ("publisher_emitted_frames", "emittedFrames"),
    ("resident_bytes", "residentBytes"),
    ("peak_resident_bytes", "peakResidentBytes"),
    ("wall_nanoseconds", "wallNanoseconds"),
    ("publisher_p95_interval_nanoseconds", "p95Interval"),
)
SEED_BASES = {"720p": 720202604, "4k": 420260804}
RESAMPLES = 100_000
BASELINE_COMMIT = "24d780d5dea98d969e3a38f300c5ffdc3f856655"
OPTIMIZED_COMMIT = "60b73098a4aa8ad704dcd55a460280f1999fc2e2"
FORMAL_HARNESS_SHA256 = (
    "a9626003badd7d56afac0297c67edefbe0e8a65c4a82664c589e383b11a58b65"
)

COMMON_RECORD_KEYS = {
    "schema_version",
    "run_index",
    "phase",
    "resolution",
    "label",
    "commit",
    "harness_sha256",
    "started_at_utc",
    "finished_at_utc",
    "exit_code",
    "sample",
    "execution",
}
FORMAL_RECORD_KEYS = COMMON_RECORD_KEYS | {"pair", "order", "sequence"}
SAMPLE_KEYS = {
    "backend",
    "bitmap_height",
    "bitmap_payload_bytes",
    "bitmap_width",
    "commands",
    "commands_per_frame",
    "compositor_errors",
    "cpu_materialization_bytes",
    "cpu_materializations",
    "cpu_nanoseconds_per_command",
    "cpu_nanoseconds_per_frame",
    "cpu_nanoseconds_per_published_frame",
    "current_metal_allocated_size",
    "damage_bytes",
    "damage_operations",
    "frames",
    "full_frame_copy_bytes",
    "gpu_copy_bytes",
    "gpu_errors",
    "height",
    "in_flight_leases",
    "last_published_revision",
    "native_video_fallbacks",
    "native_video_frames",
    "partial_frame_copy_bytes",
    "peak_resident_bytes",
    "pool_exhaustions",
    "process_cpu_nanoseconds",
    "published_fps_milli",
    "publisher_emitted_frames",
    "publisher_interval_nanoseconds",
    "publisher_p95_interval_nanoseconds",
    "publisher_pending_evictions",
    "publisher_pending_surfaces",
    "publisher_snapshot_attempts",
    "publisher_stale_snapshots",
    "publisher_submissions",
    "recommended_maximum_working_set_size",
    "resident_bytes",
    "resolution",
    "revisioned_allocated_bytes",
    "revisioned_allocated_frames",
    "revisioned_backing_enabled",
    "schema_version",
    "snapshots",
    "wall_nanoseconds",
    "width",
}
DIAGNOSTIC_SAMPLE_KEYS = SAMPLE_KEYS | {
    "bitmap_damage_journal_sample_period",
    "bitmap_damage_journal_sampled_nanoseconds",
    "bitmap_damage_journal_samples",
    "bitmap_mutation_sample_period",
    "bitmap_mutation_sampled_nanoseconds",
    "bitmap_mutation_samples",
    "bitmap_surface_store_round_trip_sample_period",
    "bitmap_surface_store_round_trip_sampled_nanoseconds",
    "bitmap_surface_store_round_trip_samples",
    "bitmap_validation_sample_period",
    "bitmap_validation_sampled_nanoseconds",
    "bitmap_validation_samples",
    "damage_rectangles_after_merge",
    "damage_rectangles_before_merge",
    "data_backend_snapshots",
    "diagnostics_enabled",
    "display_message_decode_sample_period",
    "display_message_decode_sampled_nanoseconds",
    "display_message_decode_samples",
    "display_message_handling_sample_period",
    "display_message_handling_sampled_nanoseconds",
    "display_message_handling_samples",
    "frame_emit_sample_period",
    "frame_emit_sampled_nanoseconds",
    "frame_emit_samples",
    "full_damage_by_area",
    "full_damage_by_count",
    "full_damage_by_explicit",
    "full_damage_by_history_gap",
    "full_damage_by_new_slot",
    "full_damage_by_surface_initialization",
    "publisher_submit_round_trip_sample_period",
    "publisher_submit_round_trip_sampled_nanoseconds",
    "publisher_submit_round_trip_samples",
    "revisioned_snapshot_fallbacks",
    "revisioned_snapshot_reuses",
    "revisioned_snapshot_uploads",
    "snapshot_catch_up_cpu_copy_bytes",
    "snapshot_checkout_sample_period",
    "snapshot_checkout_sampled_nanoseconds",
    "snapshot_checkout_samples",
    "snapshot_cpu_copy_sample_period",
    "snapshot_cpu_copy_sampled_nanoseconds",
    "snapshot_cpu_copy_samples",
    "snapshot_damage_plan_sample_period",
    "snapshot_damage_plan_sampled_nanoseconds",
    "snapshot_damage_plan_samples",
    "snapshot_finish_sample_period",
    "snapshot_finish_sampled_nanoseconds",
    "snapshot_finish_samples",
    "unified_backing_disables",
    "wire_framer_append_sample_period",
    "wire_framer_append_sampled_nanoseconds",
    "wire_framer_append_samples",
    "wire_framer_next_sample_period",
    "wire_framer_next_sampled_nanoseconds",
    "wire_framer_next_samples",
}
DIAGNOSTIC_RECORD_KEYS = {
    "schema_version",
    "phase",
    "run_index",
    "resolution",
    "backend",
    "commit",
    "harness_sha256",
    "started_at_utc",
    "finished_at_utc",
    "exit_code",
    "execution",
    "sample",
}
EXECUTION = {
    "scope": "host-outside-codex-sandbox",
    "fresh_process": True,
    "build_configuration": "release",
    "command": [
        "swift",
        "test",
        "-c",
        "release",
        "--skip-build",
        "--disable-sandbox",
        "--filter",
        "CPUHotPathBenchmarkTests",
    ],
}
UTC_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")


class XorShift32:
    """The exact small PRNG used to generate the checked-in evidence."""

    def __init__(self, seed: int) -> None:
        self.state = seed & 0xFFFF_FFFF

    def random(self) -> float:
        state = self.state
        state ^= (state << 13) & 0xFFFF_FFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFF_FFFF
        self.state = state & 0xFFFF_FFFF
        return self.state / 4_294_967_296


def bootstrap_median_ci(ratios: list[float], seed: int) -> dict[str, int | float]:
    generator = XorShift32(seed)
    medians: list[float] = []
    for _ in range(RESAMPLES):
        sample = [ratios[int(generator.random() * len(ratios))] for _ in ratios]
        medians.append(statistics.median(sample))
    medians.sort()
    return {
        "low": medians[2_500],
        "high": medians[97_500],
        "resamples": RESAMPLES,
        "seed": seed,
    }


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def normalize_integral_floats(value: Any) -> Any:
    """Match the checked-in JSON representation without changing its values."""
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, list):
        return [normalize_integral_floats(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize_integral_floats(item) for key, item in value.items()}
    return value


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    require(path.is_file(), f"{path}: missing evidence file")
    lines = path.read_text(encoding="utf-8").splitlines()
    require(lines, f"{path}: empty evidence file")
    require(all(line.strip() for line in lines), f"{path}: blank JSONL record")
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, start=1):
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{path}:{line_number}: invalid JSON: {error}") from error
        require(isinstance(record, dict), f"{path}:{line_number}: record is not an object")
        records.append(record)
    return records


def parse_utc(value: Any, context: str) -> datetime:
    require(isinstance(value, str), f"{context}: timestamp is not a string")
    require(UTC_PATTERN.fullmatch(value) is not None, f"{context}: timestamp is not UTC milliseconds")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise ValueError(f"{context}: invalid timestamp: {error}") from error


def require_nonempty_strings(mapping: Any, keys: set[str], context: str) -> None:
    require(isinstance(mapping, dict), f"{context}: not an object")
    require(set(mapping) == keys, f"{context}: unexpected fields")
    for key in keys:
        require(
            isinstance(mapping.get(key), str) and bool(mapping[key]),
            f"{context}: invalid {key}",
        )


def load_metadata(directory: Path) -> dict[str, Any]:
    path = directory / "metadata.json"
    require(path.is_file(), f"{path}: missing metadata")
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"{path}: invalid JSON: {error}") from error
    require(isinstance(metadata, dict), f"{path}: metadata is not an object")
    require(
        set(metadata)
        == {
            "schema_version",
            "experiment_id",
            "run_window_utc",
            "host",
            "formal",
            "diagnostics",
            "statistics",
        },
        f"{path}: unexpected metadata schema",
    )
    require(metadata.get("schema_version") == 1, f"{path}: wrong metadata schema")
    require(
        metadata.get("experiment_id") == "CPUHotPath_2026-08-04",
        f"{path}: wrong experiment identifier",
    )

    run_window = metadata.get("run_window_utc")
    require(isinstance(run_window, dict), f"{path}: run window is not an object")
    require(set(run_window) == {"started", "finished"}, f"{path}: wrong run-window schema")
    run_started = parse_utc(run_window.get("started"), f"{path} run-window start")
    run_finished = parse_utc(run_window.get("finished"), f"{path} run-window finish")
    require(run_started < run_finished, f"{path}: non-positive run window")

    host = metadata.get("host")
    require(isinstance(host, dict), f"{path}: host is not an object")
    require(
        set(host) == {"collected_at_utc", "os", "kernel", "hardware", "toolchain"},
        f"{path}: unexpected host schema",
    )
    require_nonempty_strings(host.get("os"), {"name", "version", "build"}, f"{path} host.os")
    require_nonempty_strings(
        host.get("kernel"), {"darwin", "architecture"}, f"{path} host.kernel"
    )
    require_nonempty_strings(
        host.get("hardware"),
        {"model_name", "model_identifier", "chip", "cores", "memory"},
        f"{path} host.hardware",
    )
    require_nonempty_strings(
        host.get("toolchain"), {"xcode", "swift", "target"}, f"{path} host.toolchain"
    )
    require(host["os"]["name"] == "macOS", f"{path}: host OS is not macOS")
    require(host["kernel"]["architecture"] == "arm64", f"{path}: host is not arm64")
    collected = parse_utc(host.get("collected_at_utc"), f"{path} host collection")
    require(collected >= run_finished, f"{path}: host metadata predates the run window")

    formal = metadata.get("formal")
    require(isinstance(formal, dict), f"{path}: formal metadata is not an object")
    require(
        set(formal)
        == {
            "baseline_implementation_commit",
            "optimized_implementation_commit",
            "common_benchmark_harness_sha256",
            "warmup_attempts",
            "formal_attempts",
            "pairs_per_resolution",
            "process_model",
            "diagnostics_environment",
            "release_test_executable_bytes",
        },
        f"{path}: unexpected formal metadata schema",
    )
    require(
        formal.get("baseline_implementation_commit") == BASELINE_COMMIT,
        f"{path}: wrong baseline commit",
    )
    require(
        formal.get("optimized_implementation_commit") == OPTIMIZED_COMMIT,
        f"{path}: wrong optimized commit",
    )
    require(
        formal.get("common_benchmark_harness_sha256") == FORMAL_HARNESS_SHA256,
        f"{path}: wrong common harness",
    )
    require(formal.get("warmup_attempts") == 4, f"{path}: wrong warmup count")
    require(formal.get("formal_attempts") == 40, f"{path}: wrong formal count")
    require(formal.get("pairs_per_resolution") == 10, f"{path}: wrong pair count")
    require(
        formal.get("process_model") == "one fresh Release swift-test process per attempt",
        f"{path}: wrong process model",
    )
    require(
        formal.get("diagnostics_environment") == "unset; disabled default",
        f"{path}: wrong formal diagnostics mode",
    )
    executable_bytes = formal.get("release_test_executable_bytes")
    require(
        isinstance(executable_bytes, dict)
        and set(executable_bytes) == {"baseline", "optimized", "delta"},
        f"{path}: wrong executable-size schema",
    )
    require(
        type(executable_bytes.get("baseline")) is int
        and executable_bytes["baseline"] > 0
        and type(executable_bytes.get("optimized")) is int
        and executable_bytes["optimized"] > 0,
        f"{path}: invalid executable sizes",
    )
    require(
        executable_bytes.get("delta")
        == executable_bytes["optimized"] - executable_bytes["baseline"],
        f"{path}: executable-size delta mismatch",
    )

    diagnostics = metadata.get("diagnostics")
    require(isinstance(diagnostics, dict), f"{path}: diagnostics metadata is not an object")
    require(
        set(diagnostics)
        == {"implementation_commit", "enhanced_benchmark_harness_sha256", "attempts", "purpose"},
        f"{path}: unexpected diagnostics metadata schema",
    )
    require(
        diagnostics.get("implementation_commit") == OPTIMIZED_COMMIT,
        f"{path}: wrong diagnostics commit",
    )
    enhanced_harness = diagnostics.get("enhanced_benchmark_harness_sha256")
    require(
        isinstance(enhanced_harness, str)
        and re.fullmatch(r"[0-9a-f]{64}", enhanced_harness) is not None,
        f"{path}: invalid diagnostics harness",
    )
    require(diagnostics.get("attempts") == 4, f"{path}: wrong diagnostics count")
    require(
        diagnostics.get("purpose")
        == "single-sample phase attribution; excluded from paired performance decision",
        f"{path}: wrong diagnostics purpose",
    )

    statistics_metadata = metadata.get("statistics")
    require(isinstance(statistics_metadata, dict), f"{path}: statistics is not an object")
    require(
        set(statistics_metadata)
        == {
            "paired_ratio",
            "estimator",
            "bootstrap",
            "resamples",
            "sorted_indices",
            "seeds",
        },
        f"{path}: unexpected statistics schema",
    )
    require(
        statistics_metadata
        == {
            "paired_ratio": "optimized / baseline",
            "estimator": "median",
            "bootstrap": "deterministic percentile bootstrap",
            "resamples": RESAMPLES,
            "sorted_indices": [2_500, 97_500],
            "seeds": SEED_BASES,
        },
        f"{path}: statistics parameters differ from analyzer",
    )
    return metadata


def validate_execution(execution: Any, resolution: str, context: str) -> None:
    require(isinstance(execution, dict), f"{context}: execution is not an object")
    require(
        set(execution) == {*EXECUTION, "environment"},
        f"{context}: unexpected execution fields",
    )
    for key, value in EXECUTION.items():
        require(execution.get(key) == value, f"{context}: wrong execution {key}")
    require(
        execution.get("environment")
        == {
            "SWIFTSPICE_CPU_HOTPATH_BENCHMARK": "1",
            "SWIFTSPICE_CPU_HOTPATH_BACKEND": "cpu-iosurface",
            "SWIFTSPICE_CPU_HOTPATH_RESOLUTION": resolution,
            "SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS": None,
        },
        f"{context}: wrong benchmark environment",
    )


def validate_diagnostic_execution(
    execution: Any, resolution: str, backend: str, context: str
) -> None:
    require(isinstance(execution, dict), f"{context}: execution is not an object")
    require(
        set(execution) == {*EXECUTION, "environment"},
        f"{context}: unexpected execution fields",
    )
    for key, value in EXECUTION.items():
        require(execution.get(key) == value, f"{context}: wrong execution {key}")
    require(
        execution.get("environment")
        == {
            "SWIFTSPICE_CPU_HOTPATH_BENCHMARK": "1",
            "SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS": "1",
            "SWIFTSPICE_CPU_HOTPATH_BACKEND": backend,
            "SWIFTSPICE_CPU_HOTPATH_RESOLUTION": resolution,
        },
        f"{context}: wrong diagnostic environment",
    )


def validate_sample(sample: Any, resolution: str, context: str) -> None:
    require(isinstance(sample, dict), f"{context}: sample is not an object")
    require(set(sample) == SAMPLE_KEYS, f"{context}: unexpected sample schema")
    require(sample.get("schema_version") == 1, f"{context}: wrong sample schema")
    require(sample.get("backend") == "cpu-iosurface", f"{context}: wrong backend")
    require(sample.get("resolution") == resolution, f"{context}: wrong resolution")
    require(sample.get("frames") == 1_500, f"{context}: wrong frame count")
    require(sample.get("commands") == 85_500, f"{context}: wrong command count")
    require(sample.get("commands_per_frame") == 57, f"{context}: wrong frame shape")
    require(sample.get("bitmap_width") == 32, f"{context}: wrong bitmap width")
    require(sample.get("bitmap_height") == 25, f"{context}: wrong bitmap height")
    require(sample.get("bitmap_payload_bytes") == 3_200, f"{context}: wrong payload")
    require(
        sample.get("publisher_interval_nanoseconds") == 16_000_000,
        f"{context}: wrong publication interval",
    )

    width, height = (1_280, 720) if resolution == "720p" else (3_840, 2_160)
    require(
        (sample.get("width"), sample.get("height")) == (width, height),
        f"{context}: wrong surface geometry",
    )
    require(sample.get("publisher_submissions") == 85_500, f"{context}: wrong submissions")
    require(
        sample.get("last_published_revision") == 85_500,
        f"{context}: incomplete final revision",
    )
    require(sample.get("damage_operations") == 85_500, f"{context}: wrong damage count")
    require(sample.get("damage_bytes") == 273_600_000, f"{context}: wrong damage bytes")

    emitted = sample.get("publisher_emitted_frames")
    require(type(emitted) is int and emitted > 0, f"{context}: no emitted frames")
    require(
        sample.get("publisher_snapshot_attempts") == emitted
        and sample.get("snapshots") == emitted,
        f"{context}: attempted, completed, and emitted snapshots differ",
    )
    require(sample.get("publisher_pending_surfaces") == 0, f"{context}: pending surface")
    require(sample.get("publisher_stale_snapshots") == 0, f"{context}: stale snapshot")
    require(sample.get("publisher_pending_evictions") == 0, f"{context}: pending eviction")

    two_frame_bytes = width * height * 4 * 2
    require(sample.get("revisioned_backing_enabled") is True, f"{context}: wrong path")
    require(sample.get("revisioned_allocated_frames") == 2, f"{context}: wrong allocation count")
    require(
        sample.get("revisioned_allocated_bytes") == two_frame_bytes,
        f"{context}: wrong allocation bytes",
    )
    require(
        sample.get("full_frame_copy_bytes") == two_frame_bytes,
        f"{context}: wrong full-copy bytes",
    )
    require(sample.get("partial_frame_copy_bytes", 0) > 0, f"{context}: no partial copies")
    require(sample.get("in_flight_leases") == 1, f"{context}: wrong lease count")

    zero_gates = (
        "cpu_materialization_bytes",
        "cpu_materializations",
        "gpu_copy_bytes",
        "gpu_errors",
        "compositor_errors",
        "native_video_frames",
        "native_video_fallbacks",
        "pool_exhaustions",
    )
    for field in zero_gates:
        require(sample.get(field) == 0, f"{context}: nonzero {field}")

    positive_fields = (
        "process_cpu_nanoseconds",
        "cpu_nanoseconds_per_frame",
        "cpu_nanoseconds_per_command",
        "cpu_nanoseconds_per_published_frame",
        "wall_nanoseconds",
        "publisher_p95_interval_nanoseconds",
        "published_fps_milli",
        "resident_bytes",
        "peak_resident_bytes",
        "recommended_maximum_working_set_size",
    )
    for field in positive_fields:
        value = sample.get(field)
        require(type(value) is int and value > 0, f"{context}: invalid {field}")
    require(
        sample["peak_resident_bytes"] >= sample["resident_bytes"],
        f"{context}: peak RSS below final RSS",
    )


def validate_diagnostic_sample(
    sample: Any, resolution: str, backend: str, context: str
) -> None:
    require(isinstance(sample, dict), f"{context}: sample is not an object")
    require(set(sample) == DIAGNOSTIC_SAMPLE_KEYS, f"{context}: unexpected sample schema")
    require(sample.get("schema_version") == 1, f"{context}: wrong sample schema")
    require(sample.get("backend") == backend, f"{context}: wrong sample backend")
    require(sample.get("resolution") == resolution, f"{context}: wrong sample resolution")
    require(sample.get("diagnostics_enabled") is True, f"{context}: diagnostics disabled")
    require(sample.get("frames") == 1_500, f"{context}: wrong frame count")
    require(sample.get("commands") == 85_500, f"{context}: wrong command count")
    require(sample.get("commands_per_frame") == 57, f"{context}: wrong frame shape")
    require(sample.get("bitmap_width") == 32, f"{context}: wrong bitmap width")
    require(sample.get("bitmap_height") == 25, f"{context}: wrong bitmap height")
    require(sample.get("bitmap_payload_bytes") == 3_200, f"{context}: wrong payload")
    require(
        sample.get("publisher_interval_nanoseconds") == 16_000_000,
        f"{context}: wrong publication interval",
    )

    width, height = (1_280, 720) if resolution == "720p" else (3_840, 2_160)
    require(
        (sample.get("width"), sample.get("height")) == (width, height),
        f"{context}: wrong surface geometry",
    )
    require(sample.get("publisher_submissions") == 85_500, f"{context}: wrong submissions")
    require(
        sample.get("last_published_revision") == 85_500,
        f"{context}: incomplete final revision",
    )
    require(sample.get("damage_operations") == 85_500, f"{context}: wrong damage count")
    require(sample.get("damage_bytes") == 273_600_000, f"{context}: wrong damage bytes")

    emitted = sample.get("publisher_emitted_frames")
    require(type(emitted) is int and emitted > 0, f"{context}: no emitted frames")
    require(
        sample.get("publisher_snapshot_attempts") == emitted
        and sample.get("snapshots") == emitted,
        f"{context}: attempted, completed, and emitted snapshots differ",
    )
    require(sample.get("publisher_pending_surfaces") == 0, f"{context}: pending surface")
    require(sample.get("publisher_stale_snapshots") == 0, f"{context}: stale snapshot")
    require(sample.get("publisher_pending_evictions") == 0, f"{context}: pending eviction")

    zero_common = (
        "cpu_materialization_bytes",
        "cpu_materializations",
        "gpu_copy_bytes",
        "gpu_errors",
        "compositor_errors",
        "native_video_frames",
        "native_video_fallbacks",
    )
    for field in zero_common:
        require(sample.get(field) == 0, f"{context}: nonzero {field}")

    positive_fields = (
        "process_cpu_nanoseconds",
        "cpu_nanoseconds_per_frame",
        "cpu_nanoseconds_per_command",
        "cpu_nanoseconds_per_published_frame",
        "wall_nanoseconds",
        "publisher_p95_interval_nanoseconds",
        "published_fps_milli",
        "resident_bytes",
        "peak_resident_bytes",
    )
    for field in positive_fields:
        value = sample.get(field)
        require(type(value) is int and value > 0, f"{context}: invalid {field}")
    require(
        sample["peak_resident_bytes"] >= sample["resident_bytes"],
        f"{context}: peak RSS below final RSS",
    )

    sampled_command_phases = (
        "bitmap_damage_journal",
        "bitmap_mutation",
        "bitmap_surface_store_round_trip",
        "bitmap_validation",
        "display_message_decode",
        "display_message_handling",
        "publisher_submit_round_trip",
    )
    for phase in sampled_command_phases:
        require(sample.get(f"{phase}_sample_period") == 64, f"{context}: wrong {phase} period")
        require(sample.get(f"{phase}_samples") == 1_335, f"{context}: wrong {phase} count")
        require(
            sample.get(f"{phase}_sampled_nanoseconds", 0) > 0,
            f"{context}: empty {phase} timing",
        )
    for phase in ("wire_framer_append", "wire_framer_next"):
        require(sample.get(f"{phase}_sample_period") == 64, f"{context}: wrong {phase} period")
        require(sample.get(f"{phase}_samples", 0) > 0, f"{context}: empty {phase} count")
        require(
            sample.get(f"{phase}_sampled_nanoseconds", 0) > 0,
            f"{context}: empty {phase} timing",
        )
    require(sample.get("frame_emit_sample_period") == 1, f"{context}: wrong emit period")
    require(sample.get("frame_emit_samples") == emitted, f"{context}: wrong emit samples")
    require(sample.get("frame_emit_sampled_nanoseconds", 0) > 0, f"{context}: empty emit timing")

    snapshot_phases = (
        "snapshot_checkout",
        "snapshot_damage_plan",
        "snapshot_cpu_copy",
        "snapshot_finish",
    )
    for phase in snapshot_phases:
        require(sample.get(f"{phase}_sample_period") == 1, f"{context}: wrong {phase} period")

    if backend == "cpu-iosurface":
        two_frame_bytes = width * height * 4 * 2
        require(sample.get("revisioned_backing_enabled") is True, f"{context}: wrong path")
        require(sample.get("revisioned_allocated_frames") == 2, f"{context}: wrong allocation count")
        require(
            sample.get("revisioned_allocated_bytes") == two_frame_bytes,
            f"{context}: wrong allocation bytes",
        )
        require(
            sample.get("full_frame_copy_bytes") == two_frame_bytes,
            f"{context}: wrong full-copy bytes",
        )
        require(sample.get("partial_frame_copy_bytes", 0) > 0, f"{context}: no partial copies")
        require(sample.get("data_backend_snapshots") == 0, f"{context}: Data fallback")
        require(sample.get("revisioned_snapshot_fallbacks") == 0, f"{context}: snapshot fallback")
        require(sample.get("unified_backing_disables") == 0, f"{context}: backing disabled")
        require(sample.get("pool_exhaustions") == 0, f"{context}: pool exhaustion")
        require(sample.get("in_flight_leases") == 1, f"{context}: wrong lease count")
        require(
            sample.get("revisioned_snapshot_uploads", 0)
            + sample.get("revisioned_snapshot_reuses", 0)
            == emitted,
            f"{context}: snapshot path mismatch",
        )
        revisioned_uploads = sample.get("revisioned_snapshot_uploads")
        require(
            type(revisioned_uploads) is int and revisioned_uploads > 0,
            f"{context}: no revisioned uploads",
        )
        for phase in snapshot_phases:
            require(
                sample.get(f"{phase}_samples") == revisioned_uploads,
                f"{context}: wrong {phase} count",
            )
            require(
                sample.get(f"{phase}_sampled_nanoseconds", 0) > 0,
                f"{context}: empty {phase} timing",
            )
    else:
        require(sample.get("revisioned_backing_enabled") is False, f"{context}: wrong path")
        require(sample.get("revisioned_allocated_frames") == 0, f"{context}: revisioned allocation")
        require(sample.get("revisioned_allocated_bytes") == 0, f"{context}: revisioned bytes")
        require(sample.get("data_backend_snapshots") == emitted, f"{context}: Data snapshots differ")
        require(sample.get("pool_exhaustions") == emitted, f"{context}: Data pool count differs")
        require(sample.get("partial_frame_copy_bytes") == 0, f"{context}: partial Data copy")
        require(sample.get("in_flight_leases") == 0, f"{context}: unexpected lease")
        require(
            sample.get("full_frame_copy_bytes") == width * height * 4 * emitted,
            f"{context}: wrong full Data copy bytes",
        )
        require(
            sample.get("revisioned_snapshot_uploads") == 0
            and sample.get("revisioned_snapshot_reuses") == 0
            and sample.get("revisioned_snapshot_fallbacks") == 0,
            f"{context}: revisioned activity on Data backend",
        )
        for phase in snapshot_phases:
            require(sample.get(f"{phase}_samples") == 0, f"{context}: unexpected {phase} count")
            require(
                sample.get(f"{phase}_sampled_nanoseconds") == 0,
                f"{context}: unexpected {phase} timing",
            )


def validate_record(record: dict[str, Any], context: str) -> tuple[datetime, datetime]:
    phase = record.get("phase")
    expected_keys = FORMAL_RECORD_KEYS if phase == "formal" else COMMON_RECORD_KEYS
    require(set(record) == expected_keys, f"{context}: unexpected record schema")
    require(record.get("schema_version") == 1, f"{context}: wrong record schema")
    require(phase in {"discarded-warmup", "formal"}, f"{context}: wrong phase")
    resolution = record.get("resolution")
    label = record.get("label")
    require(resolution in {"720p", "4k"}, f"{context}: wrong resolution")
    require(label in {"baseline", "optimized"}, f"{context}: wrong label")
    expected_commit = BASELINE_COMMIT if label == "baseline" else OPTIMIZED_COMMIT
    require(record.get("commit") == expected_commit, f"{context}: wrong implementation commit")
    require(
        record.get("harness_sha256") == FORMAL_HARNESS_SHA256,
        f"{context}: wrong harness",
    )
    require(type(record.get("run_index")) is int, f"{context}: invalid run index")
    require(type(record.get("exit_code")) is int, f"{context}: invalid exit code")
    require(record.get("exit_code") == 0, f"{context}: benchmark process failed")
    require("sample" in record, f"{context}: missing sample")
    require("output_tail" not in record, f"{context}: failed-attempt output found")
    validate_sample(record["sample"], resolution, context)
    validate_execution(record["execution"], resolution, context)

    started = parse_utc(record.get("started_at_utc"), f"{context} start")
    finished = parse_utc(record.get("finished_at_utc"), f"{context} finish")
    require(started < finished, f"{context}: non-positive run duration")
    return started, finished


def expected_formal_order(pair_number: int) -> tuple[str, list[str]]:
    labels = (
        ["baseline", "optimized"]
        if pair_number % 2 == 1
        else ["optimized", "baseline"]
    )
    return "-then-".join(labels), labels


def load_pairs(records: list[dict[str, Any]], resolution: str) -> list[dict[str, Any]]:
    require(len(records) == 20, f"{resolution}: expected 20 formal samples")
    pairs: list[dict[str, Any]] = []
    for offset in range(0, len(records), 2):
        pair_number = offset // 2 + 1
        entries = records[offset : offset + 2]
        order, labels = expected_formal_order(pair_number)
        require(
            [entry.get("pair") for entry in entries] == [pair_number, pair_number],
            f"{resolution} pair {pair_number}: wrong raw pair order",
        )
        require(
            [entry.get("sequence") for entry in entries] == [1, 2],
            f"{resolution} pair {pair_number}: wrong raw sequence",
        )
        require(
            [entry.get("label") for entry in entries] == labels,
            f"{resolution} pair {pair_number}: wrong AB/BA order",
        )
        require(
            [entry.get("order") for entry in entries] == [order, order],
            f"{resolution} pair {pair_number}: wrong order annotation",
        )
        require(
            [entry.get("resolution") for entry in entries] == [resolution, resolution],
            f"{resolution} pair {pair_number}: mixed resolution",
        )
        require(
            [entry.get("phase") for entry in entries] == ["formal", "formal"],
            f"{resolution} pair {pair_number}: non-formal record",
        )
        pairs.append({"pair": pair_number, "order": order, "samples": entries})
    return pairs


def classify(ci: dict[str, int | float]) -> str:
    if ci["high"] < 1:
        return "decrease-detected"
    if ci["low"] > 1:
        return "increase-detected"
    return "no-reliable-change"


def summarize(pairs: list[dict[str, Any]], seed_base: int) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    for index, (metric, name) in enumerate(METRICS):
        baseline: list[int] = []
        optimized: list[int] = []
        ratios: list[float] = []
        ratio_orders: list[str] = []
        for pair in pairs:
            by_label = {entry["label"]: entry["sample"] for entry in pair["samples"]}
            baseline_value = by_label["baseline"][metric]
            optimized_value = by_label["optimized"][metric]
            baseline.append(baseline_value)
            optimized.append(optimized_value)
            ratios.append(optimized_value / baseline_value)
            ratio_orders.append(pair["order"])

        ci = bootstrap_median_ci(ratios, seed_base + index)
        order_specific: dict[str, Any] = {}
        for order in ("baseline-then-optimized", "optimized-then-baseline"):
            order_ratios = [
                ratio
                for ratio, ratio_order in zip(ratios, ratio_orders, strict=True)
                if ratio_order == order
            ]
            order_specific[order] = {
                "count": len(order_ratios),
                "pairedMedianRatio": statistics.median(order_ratios),
                "pairedRatios": order_ratios,
            }
        rows.append(
            {
                "metric": metric,
                "name": name,
                "baselineMedian": statistics.median(baseline),
                "optimizedMedian": statistics.median(optimized),
                "pairedRatios": ratios,
                "pairedMedianRatio": statistics.median(ratios),
                "ci95": ci,
                "outcome": classify(ci),
                "orderSpecific": order_specific,
            }
        )

    pair_table: list[dict[str, Any]] = []
    for pair in pairs:
        by_label = {entry["label"]: entry["sample"] for entry in pair["samples"]}
        baseline = by_label["baseline"]
        optimized = by_label["optimized"]
        pair_table.append(
            {
                "pair": pair["pair"],
                "order": pair["order"],
                "baselineCPUPerFrame": baseline["cpu_nanoseconds_per_frame"],
                "optimizedCPUPerFrame": optimized["cpu_nanoseconds_per_frame"],
                "cpuRatio": optimized["cpu_nanoseconds_per_frame"]
                / baseline["cpu_nanoseconds_per_frame"],
                "baselineRSS": baseline["resident_bytes"],
                "optimizedRSS": optimized["resident_bytes"],
                "rssRatio": optimized["resident_bytes"] / baseline["resident_bytes"],
                "baselineEmitted": baseline["publisher_emitted_frames"],
                "optimizedEmitted": optimized["publisher_emitted_frames"],
            }
        )
    return {"pairs": len(pairs), "rows": rows, "pairTable": pair_table}


def audit_diagnostics(directory: Path, metadata: dict[str, Any]) -> None:
    records = load_jsonl(directory / "diagnostics.jsonl")
    diagnostics_metadata = metadata["diagnostics"]
    require(
        len(records) == diagnostics_metadata["attempts"] == 4,
        "diagnostics.jsonl: expected four records",
    )
    expected_shape = [
        ("720p", "data-only"),
        ("720p", "cpu-iosurface"),
        ("4k", "data-only"),
        ("4k", "cpu-iosurface"),
    ]
    previous_finish: datetime | None = None
    for expected_index, (record, (resolution, backend)) in enumerate(
        zip(records, expected_shape, strict=True), start=1
    ):
        context = f"diagnostic {expected_index}"
        require(set(record) == DIAGNOSTIC_RECORD_KEYS, f"{context}: unexpected record schema")
        require(record.get("schema_version") == 1, f"{context}: wrong record schema")
        require(record.get("phase") == "diagnostic", f"{context}: wrong phase")
        require(record.get("run_index") == expected_index, f"{context}: wrong run index")
        require(record.get("resolution") == resolution, f"{context}: wrong resolution order")
        require(record.get("backend") == backend, f"{context}: wrong backend order")
        require(
            record.get("commit") == diagnostics_metadata["implementation_commit"],
            f"{context}: wrong implementation commit",
        )
        require(
            record.get("harness_sha256")
            == diagnostics_metadata["enhanced_benchmark_harness_sha256"],
            f"{context}: wrong enhanced harness",
        )
        require(type(record.get("exit_code")) is int, f"{context}: invalid exit code")
        require(record.get("exit_code") == 0, f"{context}: diagnostic process failed")
        require("sample" in record, f"{context}: missing sample")
        require("output_tail" not in record, f"{context}: failed-attempt output found")
        validate_diagnostic_sample(record["sample"], resolution, backend, context)
        validate_diagnostic_execution(record["execution"], resolution, backend, context)
        started = parse_utc(record.get("started_at_utc"), f"{context} start")
        finished = parse_utc(record.get("finished_at_utc"), f"{context} finish")
        require(started < finished, f"{context}: non-positive run duration")
        if previous_finish is not None:
            require(started >= previous_finish, f"{context}: timestamp overlaps prior diagnostic")
        previous_finish = finished


def audit_attempts(
    directory: Path, metadata: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    attempts = load_jsonl(directory / "attempts.jsonl")
    warmups = load_jsonl(directory / "warmups.jsonl")
    formal_720p = load_jsonl(directory / "formal_720p.jsonl")
    formal_4k = load_jsonl(directory / "formal_4k.jsonl")
    require(len(attempts) == 44, "attempts.jsonl: expected 44 attempts")
    require(len(warmups) == 4, "warmups.jsonl: expected four discarded warmups")
    require(len(formal_720p) == 20, "formal_720p.jsonl: expected 20 records")
    require(len(formal_4k) == 20, "formal_4k.jsonl: expected 20 records")
    require(warmups == attempts[:4], "warmups.jsonl does not match attempts raw order")
    require(
        formal_720p == attempts[4:24],
        "formal_720p.jsonl does not match attempts raw order",
    )
    require(
        formal_4k == attempts[24:44],
        "formal_4k.jsonl does not match attempts raw order",
    )

    warmup_shape = [
        ("720p", "baseline"),
        ("720p", "optimized"),
        ("4k", "optimized"),
        ("4k", "baseline"),
    ]
    require(
        [(record.get("resolution"), record.get("label")) for record in warmups]
        == warmup_shape,
        "warmups.jsonl: unexpected warmup order",
    )
    require(
        all(record.get("phase") == "discarded-warmup" for record in warmups),
        "warmups.jsonl: non-warmup record",
    )

    previous_finish: datetime | None = None
    first_started: datetime | None = None
    last_finished: datetime | None = None
    for expected_index, record in enumerate(attempts, start=1):
        context = f"attempt {expected_index}"
        require(record.get("run_index") == expected_index, f"{context}: discontinuous run index")
        started, finished = validate_record(record, context)
        if previous_finish is not None:
            require(started >= previous_finish, f"{context}: timestamp overlaps prior attempt")
        if first_started is None:
            first_started = started
        previous_finish = finished
        last_finished = finished

    pairs_720p = load_pairs(formal_720p, "720p")
    pairs_4k = load_pairs(formal_4k, "4k")
    require(first_started is not None and last_finished is not None, "no attempt timestamps")
    metadata_window = metadata["run_window_utc"]
    require(
        metadata_window["started"] == attempts[0]["started_at_utc"]
        and metadata_window["finished"] == attempts[-1]["finished_at_utc"],
        "metadata run window does not match attempts",
    )
    require(
        parse_utc(metadata["host"]["collected_at_utc"], "host collection")
        >= last_finished,
        "host metadata predates the run window",
    )

    attempt_audit = {
        "attempts": len(attempts),
        "warmups": len(warmups),
        "formal": len(formal_720p) + len(formal_4k),
        "failures": 0,
        "runIndicesContinuous": True,
        "timestampsMonotonic": True,
        "formalHarnesses": [FORMAL_HARNESS_SHA256],
        "commits": [BASELINE_COMMIT, OPTIMIZED_COMMIT],
    }
    run_window = metadata_window
    return pairs_720p, pairs_4k, {"audit": attempt_audit, "window": run_window}


def analyze(directory: Path) -> dict[str, Any]:
    metadata = load_metadata(directory)
    pairs_720p, pairs_4k, attempt_metadata = audit_attempts(directory, metadata)
    audit_diagnostics(directory, metadata)
    formal_metadata = metadata["formal"]
    result = {
        "schemaVersion": 2,
        "method": (
            "paired optimized/baseline ratios; median; deterministic "
            "100000-resample percentile bootstrap; sorted indices 2500 and 97500"
        ),
        "provenance": {
            "baselineCommit": formal_metadata["baseline_implementation_commit"],
            "optimizedCommit": formal_metadata["optimized_implementation_commit"],
            "formalHarnessSHA256": formal_metadata["common_benchmark_harness_sha256"],
        },
        "attemptAudit": attempt_metadata["audit"],
        "resolution720p": summarize(pairs_720p, SEED_BASES["720p"]),
        "resolution4k": summarize(pairs_4k, SEED_BASES["4k"]),
        "host": metadata["host"],
        "runWindowUTC": attempt_metadata["window"],
    }
    return normalize_integral_floats(result)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument(
        "--check",
        action="store_true",
        help="also require the recomputed object to equal directory/stats.json",
    )
    args = parser.parse_args()
    result = analyze(args.directory)
    rendered = json.dumps(result, indent=2, separators=(",", ": ")) + "\n"
    if args.check:
        expected_path = args.directory / "stats.json"
        require(expected_path.is_file(), f"{expected_path}: missing expected statistics")
        expected_text = expected_path.read_text(encoding="utf-8")
        expected = json.loads(expected_text)
        require(result == expected, f"{expected_path}: recomputed statistics differ")
        require(rendered == expected_text, f"{expected_path}: JSON representation differs")
    print(rendered, end="")


if __name__ == "__main__":
    main()
