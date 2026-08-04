#!/usr/bin/env python3
"""Audit and summarize commit-to-commit CPU saturation A/B evidence.

Evidence intentionally records and requires the exact runner and analyzer
bytes. Revalidate historical evidence from the originating repository commit;
using a later analyzer would otherwise silently change its gates or statistics.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROTOCOL = "cpu-saturation-commit-ab-v1"
PRIMARY_METRIC = "ingest_cpu_nanoseconds_per_command"
SECONDARY_METRICS = (
    "end_to_end_cpu_nanoseconds_per_command",
    "resident_bytes",
    "peak_resident_bytes",
)
METRICS = (PRIMARY_METRIC, *SECONDARY_METRICS)
RESOLUTIONS = ("720p", "4k")
PAIR_COUNT = 10
WARMUP_COUNT = 4
FORMAL_COUNT = PAIR_COUNT * 2 * len(RESOLUTIONS)
FORMAL_FRAMES = 6_000
RESAMPLES = 100_000
SEEDS = {"720p": 720_202_604, "4k": 420_260_804}
TOOL_PATHS = {
    "runner": {
        "repository_path": "Benchmarks/run_cpu_saturation_ab.py",
        "evidence_path": "tools/run_cpu_saturation_ab.py",
    },
    "analyzer": {
        "repository_path": "Benchmarks/analyze_cpu_saturation.py",
        "evidence_path": "tools/analyze_cpu_saturation.py",
    },
}
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
UTC_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")

TIMING_PREFIXES = (
    "wire_framer_next",
    "wire_framer_append",
    "display_message_handling",
    "display_message_decode",
    "bitmap_surface_store_round_trip",
    "publisher_submit_round_trip",
    "frame_emit",
    "bitmap_validation",
    "bitmap_mutation",
    "bitmap_damage_journal",
    "snapshot_checkout",
    "snapshot_damage_plan",
    "snapshot_cpu_copy",
    "snapshot_finish",
)
TIMING_KEYS = {
    f"{prefix}_{suffix}"
    for prefix in TIMING_PREFIXES
    for suffix in ("sample_period", "samples", "sampled_nanoseconds")
}
SAMPLE_KEYS = {
    "schema_version",
    "backend",
    "input_mode",
    "resolution",
    "width",
    "height",
    "frames",
    "commands",
    "benchmark_process_id",
    "diagnostics_enabled",
    "commands_per_frame",
    "bitmap_width",
    "bitmap_height",
    "bitmap_payload_bytes",
    "publisher_interval_nanoseconds",
    "ingest_wall_nanoseconds",
    "ingest_process_cpu_nanoseconds",
    "ingest_cpu_nanoseconds_per_frame",
    "ingest_cpu_nanoseconds_per_command",
    "end_to_end_wall_nanoseconds",
    "end_to_end_process_cpu_nanoseconds",
    "end_to_end_cpu_nanoseconds_per_frame",
    "end_to_end_cpu_nanoseconds_per_command",
    "wall_nanoseconds",
    "process_cpu_nanoseconds",
    "cpu_nanoseconds_per_frame",
    "cpu_nanoseconds_per_command",
    "cpu_nanoseconds_per_published_frame",
    "resident_bytes",
    "peak_resident_bytes",
    "published_fps_milli",
    "publisher_p95_interval_nanoseconds",
    "last_published_revision",
    "publisher_submissions",
    "publisher_snapshot_attempts",
    "publisher_emitted_frames",
    "publisher_stale_snapshots",
    "publisher_pending_evictions",
    "publisher_pending_surfaces",
    "damage_operations",
    "damage_bytes",
    "damage_rectangles_before_merge",
    "damage_rectangles_after_merge",
    "full_damage_by_count",
    "full_damage_by_area",
    "full_damage_by_explicit",
    "full_damage_by_surface_initialization",
    "full_damage_by_new_slot",
    "full_damage_by_history_gap",
    "snapshots",
    "full_frame_copy_bytes",
    "partial_frame_copy_bytes",
    "snapshot_catch_up_cpu_copy_bytes",
    "cpu_materializations",
    "cpu_materialization_bytes",
    "pool_exhaustions",
    "in_flight_leases",
    "revisioned_backing_enabled",
    "revisioned_allocated_frames",
    "revisioned_allocated_bytes",
    "recommended_maximum_working_set_size",
    "current_metal_allocated_size",
    "gpu_copy_bytes",
    "gpu_errors",
    "compositor_errors",
    "native_video_frames",
    "native_video_fallbacks",
    "revisioned_snapshot_reuses",
    "revisioned_snapshot_uploads",
    "data_backend_snapshots",
    "revisioned_snapshot_fallbacks",
    "unified_backing_disables",
} | TIMING_KEYS

RECORD_KEYS = {
    "schema_version",
    "status",
    "run_index",
    "phase",
    "resolution",
    "label",
    "commit",
    "harness_sha256",
    "pair",
    "order",
    "sequence",
    "started_at_utc",
    "finished_at_utc",
    "exit_code",
    "sample",
    "execution",
    "log",
    "failure",
}
EXPECTED_MANIFEST_PATHS = {
    "metadata.json",
    "stats.json",
    "attempts.jsonl",
    "warmups.jsonl",
    "formal_720p.jsonl",
    "formal_4k.jsonl",
    "logs/build-baseline.log",
    "logs/build-optimized.log",
    "tools/run_cpu_saturation_ab.py",
    "tools/analyze_cpu_saturation.py",
} | {f"logs/attempt-{index:03d}.log" for index in range(1, 45)}


class EvidenceError(ValueError):
    """Raised when evidence violates the declared protocol."""


class XorShift32:
    """Small deterministic PRNG used by the percentile bootstrap."""

    def __init__(self, seed: int) -> None:
        self.state = seed & 0xFFFF_FFFF

    def random(self) -> float:
        state = self.state
        state ^= (state << 13) & 0xFFFF_FFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFF_FFFF
        self.state = state & 0xFFFF_FFFF
        return self.state / 4_294_967_296


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def require_int(value: Any, context: str, *, minimum: int | None = None) -> int:
    require(type(value) is int, f"{context}: expected integer")
    if minimum is not None:
        require(value >= minimum, f"{context}: must be >= {minimum}")
    return value


def parse_utc(value: Any, context: str) -> datetime:
    require(isinstance(value, str), f"{context}: expected timestamp string")
    require(UTC_PATTERN.fullmatch(value) is not None, f"{context}: wrong UTC format")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise EvidenceError(f"{context}: invalid timestamp: {error}") from error


def load_json(path: Path) -> dict[str, Any]:
    require(path.is_file(), f"{path}: missing file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise EvidenceError(f"{path}: invalid JSON: {error}") from error
    require(isinstance(value, dict), f"{path}: expected object")
    return value


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    require(path.is_file(), f"{path}: missing file")
    lines = path.read_text(encoding="utf-8").splitlines()
    require(lines, f"{path}: empty file")
    require(all(line.strip() for line in lines), f"{path}: blank JSONL record")
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, start=1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise EvidenceError(f"{path}:{line_number}: invalid JSON: {error}") from error
        require(isinstance(value, dict), f"{path}:{line_number}: expected object")
        records.append(value)
    return records


def file_evidence(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    return {
        "path": path.name if path.parent.name != "logs" else f"logs/{path.name}",
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
    }


def validate_manifest(directory: Path) -> None:
    manifest_path = directory / "SHA256SUMS"
    require(manifest_path.is_file(), f"{manifest_path}: missing manifest")
    try:
        manifest_text = manifest_path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError(f"{manifest_path}: manifest is not UTF-8") from error
    lines = manifest_text.splitlines()
    require(lines, f"{manifest_path}: empty manifest")
    require(manifest_text.endswith("\n"), f"{manifest_path}: missing final newline")
    require(all(line.strip() for line in lines), f"{manifest_path}: blank manifest line")

    entries: dict[str, str] = {}
    for line_number, line in enumerate(lines, start=1):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        require(match is not None, f"{manifest_path}:{line_number}: malformed entry")
        digest, relative = match.groups()
        candidate = Path(relative)
        require(
            not candidate.is_absolute() and ".." not in candidate.parts,
            f"{manifest_path}:{line_number}: unsafe path",
        )
        require(relative != "SHA256SUMS", f"{manifest_path}: manifest must not hash itself")
        require(relative not in entries, f"{manifest_path}: duplicate path {relative}")
        entries[relative] = digest

    require(
        set(entries) == EXPECTED_MANIFEST_PATHS,
        f"{manifest_path}: expected evidence paths differ from manifest",
    )
    actual_paths: set[str] = set()
    for path in directory.rglob("*"):
        require(not path.is_symlink(), f"{manifest_path}: symlink is not allowed: {path}")
        if path.is_file() and path != manifest_path:
            actual_paths.add(path.relative_to(directory).as_posix())
    require(
        actual_paths == EXPECTED_MANIFEST_PATHS,
        f"{manifest_path}: actual evidence files differ from protocol",
    )
    expected_lines: list[str] = []
    for relative in sorted(EXPECTED_MANIFEST_PATHS):
        actual_digest = hashlib.sha256((directory / relative).read_bytes()).hexdigest()
        require(
            entries[relative] == actual_digest,
            f"{manifest_path}: SHA mismatch for {relative}",
        )
        expected_lines.append(f"{actual_digest}  {relative}")
    require(
        manifest_text == "\n".join(expected_lines) + "\n",
        f"{manifest_path}: entries are not in canonical sorted form",
    )


def validate_file_evidence(directory: Path, value: Any, context: str) -> None:
    require(isinstance(value, dict), f"{context}: log metadata is not an object")
    require(set(value) == {"path", "sha256", "bytes"}, f"{context}: wrong log schema")
    relative = value.get("path")
    require(isinstance(relative, str) and relative, f"{context}: invalid log path")
    candidate = Path(relative)
    require(not candidate.is_absolute() and ".." not in candidate.parts, f"{context}: unsafe log path")
    path = directory / candidate
    require(path.is_file(), f"{context}: missing retained log {relative}")
    actual = file_evidence(path)
    require(actual["sha256"] == value.get("sha256"), f"{context}: log SHA mismatch")
    require(actual["bytes"] == value.get("bytes"), f"{context}: log size mismatch")


def extract_sample_from_log(path: Path, context: str) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    for raw_line in path.read_bytes().decode("utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line.startswith("{") or not line.endswith("}"):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            isinstance(value, dict)
            and value.get("schema_version") == 2
            and value.get("backend") == "cpu-iosurface"
            and value.get("input_mode") == "saturation"
        ):
            candidates.append(value)
    require(
        len(candidates) == 1,
        f"{context}: retained log must contain exactly one schema-2 "
        f"cpu-iosurface saturation sample; found {len(candidates)}",
    )
    return candidates[0]


def validate_metadata(directory: Path) -> dict[str, Any]:
    path = directory / "metadata.json"
    metadata = load_json(path)
    require(
        set(metadata)
        == {
            "schema_version",
            "protocol",
            "status",
            "run_window_utc",
            "host",
            "provenance",
            "workload",
            "statistics",
            "execution",
            "builds",
        },
        f"{path}: unexpected metadata schema",
    )
    require(metadata.get("schema_version") == 2, f"{path}: only schema 2 is accepted")
    require(metadata.get("protocol") == PROTOCOL, f"{path}: wrong protocol")
    require(metadata.get("status") == "complete", f"{path}: run is not complete")

    run_window = metadata.get("run_window_utc")
    require(isinstance(run_window, dict), f"{path}: run window is not an object")
    require(set(run_window) == {"started", "finished"}, f"{path}: wrong run-window schema")
    run_started = parse_utc(run_window["started"], f"{path} start")
    run_finished = parse_utc(run_window["finished"], f"{path} finish")
    require(run_started < run_finished, f"{path}: non-positive run window")

    host = metadata.get("host")
    require(isinstance(host, dict), f"{path}: host is not an object")
    require(
        set(host)
        == {
            "system",
            "machine",
            "hardware_model",
            "cpu_brand",
            "boot_epoch_seconds",
            "boot_time_utc",
            "collected_at_utc",
            "os_version",
            "os_build",
            "swift",
            "xcode",
        },
        f"{path}: wrong host schema",
    )
    require(host.get("system") == "Darwin", f"{path}: host is not macOS")
    require(host.get("machine") == "arm64", f"{path}: host is not Apple Silicon")
    for key in ("hardware_model", "cpu_brand", "os_version", "os_build", "swift", "xcode"):
        require(isinstance(host.get(key), str) and host[key], f"{path}: empty host {key}")
    boot_epoch = require_int(
        host.get("boot_epoch_seconds"), f"{path} boot epoch", minimum=1
    )
    boot_time = parse_utc(host.get("boot_time_utc"), f"{path} boot time")
    require(
        int(boot_time.timestamp()) == boot_epoch,
        f"{path}: boot epoch and boot UTC differ",
    )
    host_collected = parse_utc(
        host.get("collected_at_utc"), f"{path} host collection"
    )
    require(boot_time < host_collected, f"{path}: boot time does not predate collection")
    require(
        host_collected <= run_started,
        f"{path}: host metadata was not collected before the attempt window",
    )

    provenance = metadata.get("provenance")
    require(isinstance(provenance, dict), f"{path}: provenance is not an object")
    require(
        set(provenance)
        == {
            "baseline_commit",
            "optimized_commit",
            "harness_path",
            "common_harness_sha256",
            "tool_commit",
            "tool_files",
        },
        f"{path}: wrong provenance schema",
    )
    for key in ("baseline_commit", "optimized_commit"):
        require(
            isinstance(provenance.get(key), str)
            and COMMIT_PATTERN.fullmatch(provenance[key]) is not None,
            f"{path}: invalid {key}",
        )
    require(
        provenance["baseline_commit"] != provenance["optimized_commit"],
        f"{path}: baseline and optimized commits are identical",
    )
    require(
        provenance.get("harness_path")
        == "Tests/SpiceCoreTests/CPUHotPathBenchmarkTests.swift",
        f"{path}: wrong harness path",
    )
    require(
        isinstance(provenance.get("common_harness_sha256"), str)
        and SHA256_PATTERN.fullmatch(provenance["common_harness_sha256"]) is not None,
        f"{path}: invalid common_harness_sha256",
    )
    require(
        isinstance(provenance.get("tool_commit"), str)
        and COMMIT_PATTERN.fullmatch(provenance["tool_commit"]) is not None,
        f"{path}: invalid tool_commit",
    )
    tool_files = provenance.get("tool_files")
    require(isinstance(tool_files, dict), f"{path}: tool_files is not an object")
    require(set(tool_files) == set(TOOL_PATHS), f"{path}: wrong tool_files schema")
    current_tool_paths = {
        "analyzer": Path(__file__).resolve(),
        "runner": Path(__file__).resolve().with_name("run_cpu_saturation_ab.py"),
    }
    for label, expected_paths in TOOL_PATHS.items():
        context = f"{path} {label} tool"
        value = tool_files.get(label)
        require(isinstance(value, dict), f"{context}: not an object")
        require(
            set(value) == {"repository_path", "evidence_path", "sha256"},
            f"{context}: wrong schema",
        )
        require(
            value.get("repository_path") == expected_paths["repository_path"],
            f"{context}: wrong repository path",
        )
        require(
            value.get("evidence_path") == expected_paths["evidence_path"],
            f"{context}: wrong evidence path",
        )
        digest = value.get("sha256")
        require(
            isinstance(digest, str) and SHA256_PATTERN.fullmatch(digest) is not None,
            f"{context}: invalid SHA",
        )
        bundled_path = directory / value["evidence_path"]
        require(bundled_path.is_file(), f"{context}: bundled file is missing")
        require(
            hashlib.sha256(bundled_path.read_bytes()).hexdigest() == digest,
            f"{context}: bundled bytes differ from provenance",
        )
        current_path = current_tool_paths[label]
        require(current_path.is_file(), f"{context}: current tool is missing")
        require(
            hashlib.sha256(current_path.read_bytes()).hexdigest() == digest,
            f"{context}: current tool bytes differ; use the bundled analyzer",
        )

    workload = metadata.get("workload")
    require(isinstance(workload, dict), f"{path}: workload is not an object")
    require(
        set(workload)
        == {
            "backend",
            "input_mode",
            "diagnostics_enabled",
            "resolutions",
            "frames",
            "commands_per_frame",
            "warmup_attempts",
            "formal_attempts",
            "pairs_per_resolution",
            "process_model",
        },
        f"{path}: wrong workload schema",
    )
    require(workload.get("backend") == "cpu-iosurface", f"{path}: wrong backend")
    require(workload.get("input_mode") == "saturation", f"{path}: wrong input mode")
    require(workload.get("diagnostics_enabled") is False, f"{path}: diagnostics enabled")
    require(workload.get("resolutions") == list(RESOLUTIONS), f"{path}: wrong resolutions")
    require(
        workload.get("frames") == FORMAL_FRAMES,
        f"{path}: formal frame count must be predeclared as {FORMAL_FRAMES}",
    )
    require(workload.get("commands_per_frame") == 57, f"{path}: wrong frame shape")
    require(workload.get("warmup_attempts") == WARMUP_COUNT, f"{path}: wrong warmup count")
    require(workload.get("formal_attempts") == FORMAL_COUNT, f"{path}: wrong formal count")
    require(workload.get("pairs_per_resolution") == PAIR_COUNT, f"{path}: wrong pair count")
    require(
        workload.get("process_model") == "one fresh Release swift-test process per attempt",
        f"{path}: wrong process model",
    )

    statistics_metadata = metadata.get("statistics")
    require(isinstance(statistics_metadata, dict), f"{path}: statistics is not an object")
    require(
        statistics_metadata
        == {
            "paired_ratio": "optimized / baseline",
            "primary_metric": PRIMARY_METRIC,
            "secondary_metrics": list(SECONDARY_METRICS),
            "estimator": "median of paired ratios",
            "bootstrap": "deterministic percentile bootstrap",
            "resamples": RESAMPLES,
            "seeds": SEEDS,
        },
        f"{path}: statistics protocol differs from analyzer",
    )

    execution = metadata.get("execution")
    require(isinstance(execution, dict), f"{path}: execution is not an object")
    require(
        set(execution) == {"scope", "host_execution_confirmed", "sample_timeout_seconds"},
        f"{path}: wrong execution schema",
    )
    require(execution.get("scope") == "host-outside-codex-sandbox", f"{path}: wrong scope")
    require(execution.get("host_execution_confirmed") is True, f"{path}: host not confirmed")
    require_int(execution.get("sample_timeout_seconds"), f"{path} timeout", minimum=1)

    builds = metadata.get("builds")
    require(isinstance(builds, list) and len(builds) == 2, f"{path}: expected two builds")
    for expected_label, build in zip(("baseline", "optimized"), builds, strict=True):
        context = f"{path} {expected_label} build"
        require(isinstance(build, dict), f"{context}: not an object")
        require(
            set(build) == {"label", "commit", "exit_code", "command", "log"},
            f"{context}: wrong schema",
        )
        require(build.get("label") == expected_label, f"{context}: wrong label")
        require(
            build.get("commit") == provenance[f"{expected_label}_commit"],
            f"{context}: wrong commit",
        )
        require(build.get("exit_code") == 0, f"{context}: build failed")
        require(isinstance(build.get("command"), list) and build["command"], f"{context}: no command")
        validate_file_evidence(directory, build.get("log"), context)
    return metadata


def validate_exact_division(sample: dict[str, Any], total: str, divisor: int, derived: str, context: str) -> None:
    total_value = require_int(sample.get(total), f"{context} {total}", minimum=1)
    require(
        sample.get(derived) == total_value // divisor,
        f"{context}: {derived} does not match integer division",
    )


def validate_sample(sample: Any, resolution: str, frames: int, context: str) -> None:
    require(isinstance(sample, dict), f"{context}: sample is not an object")
    require(set(sample) == SAMPLE_KEYS, f"{context}: unexpected schema-2 sample fields")
    require(sample.get("schema_version") == 2, f"{context}: only sample schema 2 is accepted")
    require(sample.get("backend") == "cpu-iosurface", f"{context}: wrong backend")
    require(sample.get("input_mode") == "saturation", f"{context}: wrong input mode")
    require(sample.get("diagnostics_enabled") is False, f"{context}: diagnostics enabled")
    require(sample.get("resolution") == resolution, f"{context}: wrong resolution")
    require(sample.get("frames") == frames, f"{context}: wrong frame count")
    require_int(
        sample.get("benchmark_process_id"),
        f"{context} benchmark process ID",
        minimum=1,
    )
    commands = frames * 57
    require(sample.get("commands") == commands, f"{context}: wrong command count")
    require(sample.get("commands_per_frame") == 57, f"{context}: wrong commands/frame")
    require(sample.get("bitmap_width") == 32, f"{context}: wrong bitmap width")
    require(sample.get("bitmap_height") == 25, f"{context}: wrong bitmap height")
    require(sample.get("bitmap_payload_bytes") == 3_200, f"{context}: wrong payload size")
    require(
        sample.get("publisher_interval_nanoseconds") == 600_000_000_000,
        f"{context}: saturation timer is not ten minutes",
    )

    width, height = (1_280, 720) if resolution == "720p" else (3_840, 2_160)
    surface_bytes = width * height * 4
    require((sample.get("width"), sample.get("height")) == (width, height), f"{context}: wrong geometry")
    require(sample.get("publisher_submissions") == commands, f"{context}: wrong submissions")
    require(sample.get("last_published_revision") == commands, f"{context}: incomplete revision")
    require(sample.get("damage_operations") == commands, f"{context}: wrong damage count")
    require(sample.get("damage_bytes") == commands * 3_200, f"{context}: wrong damage bytes")

    exact_one = (
        "publisher_snapshot_attempts",
        "publisher_emitted_frames",
        "snapshots",
        "revisioned_snapshot_uploads",
        "in_flight_leases",
        "revisioned_allocated_frames",
        "damage_rectangles_after_merge",
        "full_damage_by_new_slot",
    )
    for field in exact_one:
        require(sample.get(field) == 1, f"{context}: {field} must equal one")
    require(sample.get("damage_rectangles_before_merge") == commands, f"{context}: wrong pre-merge damage count")
    require(sample.get("revisioned_allocated_bytes") == surface_bytes, f"{context}: wrong IOSurface bytes")
    require(sample.get("full_frame_copy_bytes") == surface_bytes, f"{context}: wrong full copy bytes")
    require(sample.get("snapshot_catch_up_cpu_copy_bytes") == surface_bytes, f"{context}: wrong catch-up bytes")
    require(sample.get("revisioned_backing_enabled") is True, f"{context}: wrong backing")
    require(sample.get("publisher_p95_interval_nanoseconds") == 0, f"{context}: more than one emission")

    zero_fields = (
        "publisher_stale_snapshots",
        "publisher_pending_evictions",
        "publisher_pending_surfaces",
        "partial_frame_copy_bytes",
        "cpu_materializations",
        "cpu_materialization_bytes",
        "pool_exhaustions",
        "gpu_copy_bytes",
        "gpu_errors",
        "compositor_errors",
        "native_video_frames",
        "native_video_fallbacks",
        "revisioned_snapshot_reuses",
        "data_backend_snapshots",
        "revisioned_snapshot_fallbacks",
        "unified_backing_disables",
        "full_damage_by_count",
        "full_damage_by_area",
        "full_damage_by_explicit",
        "full_damage_by_surface_initialization",
        "full_damage_by_history_gap",
    )
    for field in zero_fields:
        require(sample.get(field) == 0, f"{context}: nonzero {field}")
    for field in TIMING_KEYS:
        require(sample.get(field) == 0, f"{context}: diagnostics timing {field} is nonzero")

    positive_fields = (
        "ingest_wall_nanoseconds",
        "ingest_process_cpu_nanoseconds",
        "ingest_cpu_nanoseconds_per_frame",
        "ingest_cpu_nanoseconds_per_command",
        "end_to_end_wall_nanoseconds",
        "end_to_end_process_cpu_nanoseconds",
        "end_to_end_cpu_nanoseconds_per_frame",
        "end_to_end_cpu_nanoseconds_per_command",
        "wall_nanoseconds",
        "process_cpu_nanoseconds",
        "cpu_nanoseconds_per_frame",
        "cpu_nanoseconds_per_command",
        "cpu_nanoseconds_per_published_frame",
        "resident_bytes",
        "peak_resident_bytes",
        "published_fps_milli",
        "recommended_maximum_working_set_size",
    )
    for field in positive_fields:
        require_int(sample.get(field), f"{context} {field}", minimum=1)
    require(sample["peak_resident_bytes"] >= sample["resident_bytes"], f"{context}: peak RSS below final RSS")
    require(sample["end_to_end_wall_nanoseconds"] >= sample["ingest_wall_nanoseconds"], f"{context}: end-to-end wall time below ingest")
    require(sample["end_to_end_process_cpu_nanoseconds"] >= sample["ingest_process_cpu_nanoseconds"], f"{context}: end-to-end CPU below ingest")

    validate_exact_division(sample, "ingest_process_cpu_nanoseconds", frames, "ingest_cpu_nanoseconds_per_frame", context)
    validate_exact_division(sample, "ingest_process_cpu_nanoseconds", commands, "ingest_cpu_nanoseconds_per_command", context)
    validate_exact_division(sample, "end_to_end_process_cpu_nanoseconds", frames, "end_to_end_cpu_nanoseconds_per_frame", context)
    validate_exact_division(sample, "end_to_end_process_cpu_nanoseconds", commands, "end_to_end_cpu_nanoseconds_per_command", context)
    validate_exact_division(sample, "process_cpu_nanoseconds", frames, "cpu_nanoseconds_per_frame", context)
    validate_exact_division(sample, "process_cpu_nanoseconds", commands, "cpu_nanoseconds_per_command", context)
    require(sample["cpu_nanoseconds_per_published_frame"] == sample["process_cpu_nanoseconds"], f"{context}: legacy published-frame CPU mismatch")


def validate_execution(execution: Any, resolution: str, frames: int, context: str) -> None:
    require(isinstance(execution, dict), f"{context}: execution is not an object")
    require(
        set(execution)
        == {
            "scope",
            "fresh_process",
            "launcher_process_id",
            "build_configuration",
            "command",
            "environment",
        },
        f"{context}: wrong execution schema",
    )
    require(execution.get("scope") == "host-outside-codex-sandbox", f"{context}: wrong scope")
    require(execution.get("fresh_process") is True, f"{context}: process was not fresh")
    require_int(
        execution.get("launcher_process_id"),
        f"{context} launcher process ID",
        minimum=1,
    )
    require(execution.get("build_configuration") == "release", f"{context}: wrong build configuration")
    command = execution.get("command")
    require(isinstance(command, list), f"{context}: command is not an array")
    require(command[:4] == ["swift", "test", "-c", "release"], f"{context}: wrong command prefix")
    require("--skip-build" in command, f"{context}: sample unexpectedly rebuilt")
    require("--disable-sandbox" in command, f"{context}: SwiftPM sandbox not disabled")
    require(command[-2:] == ["--filter", "CPUHotPathBenchmarkTests"], f"{context}: wrong test filter")
    require(
        execution.get("environment")
        == {
            "SWIFTSPICE_CPU_HOTPATH_BENCHMARK": "1",
            "SWIFTSPICE_CPU_HOTPATH_BACKEND": "cpu-iosurface",
            "SWIFTSPICE_CPU_HOTPATH_INPUT_MODE": "saturation",
            "SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS": "0",
            "SWIFTSPICE_CPU_HOTPATH_RESOLUTION": resolution,
            "SWIFTSPICE_CPU_HOTPATH_FRAMES": str(frames),
        },
        f"{context}: wrong benchmark environment",
    )


def expected_formal_order(pair_number: int) -> tuple[str, list[str]]:
    labels = ["baseline", "optimized"] if pair_number % 2 else ["optimized", "baseline"]
    return "-then-".join(labels), labels


def validate_record(
    directory: Path,
    record: dict[str, Any],
    metadata: dict[str, Any],
    expected_index: int,
    context: str,
) -> tuple[datetime, datetime]:
    require(set(record) == RECORD_KEYS, f"{context}: unexpected record schema")
    require(record.get("schema_version") == 2, f"{context}: wrong record schema")
    require(record.get("status") == "succeeded", f"{context}: retained attempt failed")
    require(record.get("failure") is None, f"{context}: successful attempt has failure data")
    require(record.get("run_index") == expected_index, f"{context}: discontinuous run index")
    phase = record.get("phase")
    require(phase in {"discarded-warmup", "formal"}, f"{context}: wrong phase")
    resolution = record.get("resolution")
    label = record.get("label")
    require(resolution in RESOLUTIONS, f"{context}: wrong resolution")
    require(label in {"baseline", "optimized"}, f"{context}: wrong label")
    provenance = metadata["provenance"]
    require(record.get("commit") == provenance[f"{label}_commit"], f"{context}: wrong commit")
    require(record.get("harness_sha256") == provenance["common_harness_sha256"], f"{context}: wrong harness")
    require(record.get("exit_code") == 0, f"{context}: benchmark process failed")
    if phase == "discarded-warmup":
        require(record.get("pair") is None, f"{context}: warmup has pair")
        require(record.get("order") is None, f"{context}: warmup has order")
        require(record.get("sequence") is None, f"{context}: warmup has sequence")
    else:
        require_int(record.get("pair"), f"{context} pair", minimum=1)
        require(record["pair"] <= PAIR_COUNT, f"{context}: pair exceeds protocol")
        require(record.get("order") in {"baseline-then-optimized", "optimized-then-baseline"}, f"{context}: bad order")
        require(record.get("sequence") in {1, 2}, f"{context}: bad sequence")
    validate_sample(record.get("sample"), resolution, metadata["workload"]["frames"], context)
    validate_execution(record.get("execution"), resolution, metadata["workload"]["frames"], context)
    validate_file_evidence(directory, record.get("log"), context)
    logged_sample = extract_sample_from_log(
        directory / record["log"]["path"], f"{context} retained log"
    )
    require(
        logged_sample == record["sample"],
        f"{context}: retained log sample differs from record.sample",
    )
    started = parse_utc(record.get("started_at_utc"), f"{context} start")
    finished = parse_utc(record.get("finished_at_utc"), f"{context} finish")
    require(started < finished, f"{context}: non-positive duration")
    return started, finished


def load_pairs(records: list[dict[str, Any]], resolution: str) -> list[dict[str, Any]]:
    require(len(records) == PAIR_COUNT * 2, f"{resolution}: expected 20 formal samples")
    pairs: list[dict[str, Any]] = []
    for offset in range(0, len(records), 2):
        pair_number = offset // 2 + 1
        entries = records[offset : offset + 2]
        order, labels = expected_formal_order(pair_number)
        require([entry["pair"] for entry in entries] == [pair_number, pair_number], f"{resolution} pair {pair_number}: wrong pair")
        require([entry["sequence"] for entry in entries] == [1, 2], f"{resolution} pair {pair_number}: wrong sequence")
        require([entry["label"] for entry in entries] == labels, f"{resolution} pair {pair_number}: wrong AB/BA order")
        require([entry["order"] for entry in entries] == [order, order], f"{resolution} pair {pair_number}: wrong order annotation")
        require(all(entry["resolution"] == resolution for entry in entries), f"{resolution} pair {pair_number}: mixed resolution")
        pairs.append({"pair": pair_number, "order": order, "samples": entries})
    return pairs


def audit_attempts(directory: Path, metadata: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    attempts = load_jsonl(directory / "attempts.jsonl")
    warmups = load_jsonl(directory / "warmups.jsonl")
    formal = {
        resolution: load_jsonl(directory / f"formal_{resolution}.jsonl")
        for resolution in RESOLUTIONS
    }
    require(len(attempts) == WARMUP_COUNT + FORMAL_COUNT, "attempts.jsonl: expected 44 retained attempts")
    require(len(warmups) == WARMUP_COUNT, "warmups.jsonl: expected four warmups")
    require(warmups == attempts[:WARMUP_COUNT], "warmups.jsonl: not the raw attempt prefix")
    require(formal["720p"] == attempts[4:24], "formal_720p.jsonl: not raw attempt order")
    require(formal["4k"] == attempts[24:44], "formal_4k.jsonl: not raw attempt order")
    require(
        [(record["resolution"], record["label"]) for record in warmups]
        == [("720p", "baseline"), ("720p", "optimized"), ("4k", "optimized"), ("4k", "baseline")],
        "warmups.jsonl: wrong balanced warmup order",
    )
    require(all(record["phase"] == "discarded-warmup" for record in warmups), "warmups.jsonl: non-warmup record")

    previous_finish: datetime | None = None
    for expected_index, record in enumerate(attempts, start=1):
        started, finished = validate_record(directory, record, metadata, expected_index, f"attempt {expected_index}")
        if previous_finish is not None:
            require(started >= previous_finish, f"attempt {expected_index}: timestamp overlaps prior attempt")
        previous_finish = finished
    require(metadata["run_window_utc"]["started"] == attempts[0]["started_at_utc"], "metadata start does not match ledger")
    require(metadata["run_window_utc"]["finished"] == attempts[-1]["finished_at_utc"], "metadata finish does not match ledger")
    return formal


def bootstrap_median_ci(ratios: list[float], seed: int, resamples: int = RESAMPLES) -> dict[str, Any]:
    require(bool(ratios), "bootstrap requires paired ratios")
    require(resamples >= 100, "bootstrap requires at least 100 resamples")
    generator = XorShift32(seed)
    medians: list[float] = []
    for _ in range(resamples):
        sample = [ratios[int(generator.random() * len(ratios))] for _ in ratios]
        medians.append(statistics.median(sample))
    medians.sort()
    low_index = int(resamples * 0.025)
    high_index = min(resamples - 1, int(resamples * 0.975))
    return {
        "low": medians[low_index],
        "high": medians[high_index],
        "resamples": resamples,
        "seed": seed,
        "sorted_indices": [low_index, high_index],
    }


def classify(ci: dict[str, Any]) -> str:
    if ci["high"] < 1:
        return "decrease-detected"
    if ci["low"] > 1:
        return "increase-detected"
    return "no-reliable-change"


def summarize(pairs: list[dict[str, Any]], seed: int, resamples: int = RESAMPLES) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    for metric_index, metric in enumerate(METRICS):
        baseline_values: list[int] = []
        optimized_values: list[int] = []
        ratios: list[float] = []
        ratio_orders: list[str] = []
        for pair in pairs:
            by_label = {entry["label"]: entry["sample"] for entry in pair["samples"]}
            baseline = by_label["baseline"][metric]
            optimized = by_label["optimized"][metric]
            baseline_values.append(baseline)
            optimized_values.append(optimized)
            ratios.append(optimized / baseline)
            ratio_orders.append(pair["order"])
        ci = bootstrap_median_ci(ratios, seed + metric_index, resamples)
        order_specific: dict[str, Any] = {}
        for order in ("baseline-then-optimized", "optimized-then-baseline"):
            selected = [ratio for ratio, seen_order in zip(ratios, ratio_orders, strict=True) if seen_order == order]
            order_specific[order] = {
                "count": len(selected),
                "paired_median_ratio": statistics.median(selected),
                "paired_ratios": selected,
            }
        rows.append(
            {
                "metric": metric,
                "role": "primary" if metric == PRIMARY_METRIC else "secondary",
                "baseline_median": statistics.median(baseline_values),
                "optimized_median": statistics.median(optimized_values),
                "paired_ratios": ratios,
                "paired_median_ratio": statistics.median(ratios),
                "ci95": ci,
                "outcome": classify(ci),
                "order_specific": order_specific,
            }
        )
    pair_table = []
    for pair in pairs:
        by_label = {entry["label"]: entry["sample"] for entry in pair["samples"]}
        baseline = by_label["baseline"]
        optimized = by_label["optimized"]
        pair_table.append(
            {
                "pair": pair["pair"],
                "order": pair["order"],
                "baseline_ingest_cpu_nanoseconds_per_command": baseline[PRIMARY_METRIC],
                "optimized_ingest_cpu_nanoseconds_per_command": optimized[PRIMARY_METRIC],
                "ingest_cpu_ratio": optimized[PRIMARY_METRIC] / baseline[PRIMARY_METRIC],
                "baseline_resident_bytes": baseline["resident_bytes"],
                "optimized_resident_bytes": optimized["resident_bytes"],
                "resident_bytes_ratio": optimized["resident_bytes"] / baseline["resident_bytes"],
            }
        )
    return {"pairs": len(pairs), "rows": rows, "pair_table": pair_table}


def normalize_integral_floats(value: Any) -> Any:
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, list):
        return [normalize_integral_floats(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize_integral_floats(item) for key, item in value.items()}
    return value


def render_statistics(result: dict[str, Any]) -> str:
    return json.dumps(result, indent=2, separators=(",", ": "), sort_keys=True) + "\n"


def validate_stored_statistics(directory: Path, result: dict[str, Any]) -> None:
    stats_path = directory / "stats.json"
    require(stats_path.is_file(), f"{stats_path}: missing stored statistics")
    expected_text = stats_path.read_text(encoding="utf-8")
    try:
        expected = json.loads(expected_text)
    except json.JSONDecodeError as error:
        raise EvidenceError(f"{stats_path}: invalid JSON: {error}") from error
    require(expected == result, f"{stats_path}: recomputed statistics differ")
    require(
        expected_text == render_statistics(result),
        f"{stats_path}: JSON representation differs",
    )


def analyze(
    directory: Path,
    *,
    resamples: int = RESAMPLES,
    verify_manifest: bool = True,
    internal_inputs_only: bool = False,
) -> dict[str, Any]:
    require(
        not internal_inputs_only or not verify_manifest,
        "internal inputs-only analysis must explicitly disable manifest verification",
    )
    if verify_manifest:
        validate_manifest(directory)
    metadata = validate_metadata(directory)
    formal = audit_attempts(directory, metadata)
    result = {
        "schema_version": 2,
        "protocol": PROTOCOL,
        "method": "paired optimized/baseline ratios; median; deterministic percentile bootstrap",
        "primary_metric": PRIMARY_METRIC,
        "provenance": {
            "baseline_commit": metadata["provenance"]["baseline_commit"],
            "optimized_commit": metadata["provenance"]["optimized_commit"],
            "common_harness_sha256": metadata["provenance"]["common_harness_sha256"],
            "tool_commit": metadata["provenance"]["tool_commit"],
            "tool_files": metadata["provenance"]["tool_files"],
        },
        "attempt_audit": {
            "attempts": WARMUP_COUNT + FORMAL_COUNT,
            "warmups": WARMUP_COUNT,
            "formal": FORMAL_COUNT,
            "failures": 0,
            "fresh_processes": True,
            "ab_ba_alternation": True,
            "schema_2_saturation_only": True,
        },
        "resolution_720p": summarize(load_pairs(formal["720p"], "720p"), SEEDS["720p"], resamples),
        "resolution_4k": summarize(load_pairs(formal["4k"], "4k"), SEEDS["4k"], resamples),
        "host": metadata["host"],
        "run_window_utc": metadata["run_window_utc"],
    }
    result = normalize_integral_floats(result)
    if not internal_inputs_only:
        validate_stored_statistics(directory, result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument(
        "--check",
        action="store_true",
        help="compatibility flag; stats.json is always verified",
    )
    args = parser.parse_args()
    result = analyze(args.directory)
    print(render_statistics(result), end="")


if __name__ == "__main__":
    main()
