#!/usr/bin/env python3
"""Analyze paired SwiftSpice and spice-client-glib2 live benchmark results."""

from __future__ import annotations

import argparse
import json
import random
import re
import statistics
from pathlib import Path

METRICS = {
    "fps": ("higher", 0.95),
    "ready_frame_ms": ("lower", 1.10),
    "p95_interframe_ms": ("lower", 1.10),
    "observe_cpu_seconds_per_frame": ("lower", 1.10),
    "maximum_rss_bytes": ("lower", 1.15),
}
EXPECTED_ACTIVITY_BUCKETS = 10
MINIMUM_ACTIVITY_FRACTION = 0.8
MAXIMUM_LAST_FRAME_AGE_MS = 1_000.0
SUPPORTED_RENDERERS = {"automatic", "cpu", "cpu-iosurface", "metal"}
SUPPORTED_VIDEO_CODECS = {"mjpeg", "h264", "h265"}
CPU_OPCODE_FIELDS = (
    "cpu_fill_operations",
    "cpu_copy_bits_operations",
    "cpu_bitmap_copy_operations",
    "cpu_surface_copy_operations",
    "cpu_scaled_copy_operations",
)


def parse_time(path: Path) -> dict[str, float]:
    values: dict[str, float] = {}
    for line in path.read_text().splitlines():
        if match := re.fullmatch(r"(real|user|sys)\s+([0-9.]+)", line.strip()):
            values[match.group(1)] = float(match.group(2))
        elif match := re.fullmatch(r"\s*([0-9]+)\s+maximum resident set size", line):
            values["maximum_rss_bytes"] = float(match.group(1))
    if "user" in values and "sys" in values:
        values["cpu_seconds"] = values["user"] + values["sys"]
    return values


def validate_swift_renderer_evidence(report: dict[str, object], path: Path) -> None:
    renderer = report.get("renderer")
    if not isinstance(renderer, str) or renderer not in SUPPORTED_RENDERERS:
        raise ValueError(f"missing or invalid renderer in {path}")

    requirements: dict[str, object]
    if renderer == "automatic":
        requirements = {
            "metal_2d_renderer_enabled": False,
            "metal_2d_command_buffers": 0,
            "metal_2d_commands": 0,
        }
    elif renderer == "cpu":
        requirements = {
            "revisioned_backing_enabled": False,
            "metal_2d_renderer_enabled": False,
            "metal_2d_command_buffers": 0,
            "metal_2d_commands": 0,
            "pool_exhaustions": 0,
            "gpu_errors": 0,
        }
    elif renderer == "cpu-iosurface":
        requirements = {
            "revisioned_backing_enabled": True,
            "metal_2d_renderer_enabled": False,
            "metal_2d_command_buffers": 0,
            "metal_2d_commands": 0,
            "pool_exhaustions": 0,
            "gpu_errors": 0,
        }
    else:
        requirements = {
            "revisioned_backing_enabled": True,
            "metal_2d_renderer_enabled": True,
            "cpu_materializations": 0,
            "gpu_errors": 0,
            "pool_exhaustions": 0,
        }

    invalid = [
        name
        for name, expected in requirements.items()
        if name not in report
        or type(report[name]) is not type(expected)
        or report[name] != expected
    ]
    if renderer == "metal":
        for name in ("metal_2d_command_buffers", "metal_2d_commands"):
            value = report.get(name)
            if type(value) is not int or value < 1:
                invalid.append(name)
    if renderer == "cpu-iosurface":
        allocated_frames = report.get("revisioned_allocated_frames")
        if type(allocated_frames) is not int or allocated_frames < 1:
            invalid.append("revisioned_allocated_frames")
    if renderer in {"cpu", "cpu-iosurface"}:
        cpu_counts = [report.get(name) for name in CPU_OPCODE_FIELDS]
        if (
            any(type(value) is not int for value in cpu_counts)
            or sum(cpu_counts) < 1
        ):
            invalid.append("cpu_opcode_operations")
    if invalid:
        raise ValueError(
            f"invalid {renderer} renderer evidence in {path}: "
            + ", ".join(invalid)
        )


def validate_swift_video_evidence(
    report: dict[str, object], video_codec: str, path: Path
) -> None:
    if video_codec == "mjpeg":
        return
    minimum_one = ("native_video_frames", "vt_decoded_frames")
    zero = (
        "vt_cpu_materializations",
        "advanced_cpu_fallback_frames",
        "gpu_errors",
        "metal_generation_disables",
    )
    invalid = []
    for name in minimum_one:
        value = report.get(name)
        if type(value) is not int or value < 1:
            invalid.append(name)
    for name in zero:
        value = report.get(name)
        if type(value) is not int or value != 0:
            invalid.append(name)
    if invalid:
        raise ValueError(
            f"invalid {video_codec} native-video evidence in {path}: "
            + ", ".join(invalid)
        )


def load_client(directory: Path, run: int, client: str) -> dict[str, object]:
    prefix = directory / f"run-{run:02d}-{client}"
    report = json.loads(prefix.with_suffix(".json").read_text())
    metadata_path = prefix.with_suffix(".meta.json")
    metadata = json.loads(metadata_path.read_text())
    if metadata.get("client") != client or int(metadata.get("run", -1)) != run:
        raise ValueError(f"sample identity mismatch in {metadata_path}")
    if int(metadata.get("exit_code", -1)) != 0:
        raise ValueError(f"client exited unsuccessfully in {metadata_path}")
    requested_renderer = metadata.get("renderer")
    if (
        not isinstance(requested_renderer, str)
        or requested_renderer not in SUPPORTED_RENDERERS
    ):
        raise ValueError(f"missing or invalid renderer in {metadata_path}")
    video_codec = metadata.get("video_codec")
    if not isinstance(video_codec, str) or video_codec not in SUPPORTED_VIDEO_CODECS:
        raise ValueError(f"missing or invalid video codec in {metadata_path}")
    if client == "swiftspice" and requested_renderer != report.get("renderer"):
        raise ValueError(f"renderer metadata mismatch in {metadata_path}")
    boot_epoch = metadata.get("boot_epoch")
    if not isinstance(boot_epoch, str) or not boot_epoch:
        raise ValueError(f"missing boot epoch in {metadata_path}")
    observe_seconds = int(report.get("observe_seconds", 0))
    if observe_seconds < 1 or observe_seconds != int(
        metadata.get("observe_seconds", -1)
    ):
        raise ValueError(f"observation duration mismatch in {metadata_path}")
    activity_requirements = {
        "frames": int(report.get("frames", 0)) >= 2,
        "expected_time_buckets": int(report.get("expected_time_buckets", 0))
        == EXPECTED_ACTIVITY_BUCKETS,
        "active_time_buckets": int(report.get("active_time_buckets", 0))
        >= int(EXPECTED_ACTIVITY_BUCKETS * MINIMUM_ACTIVITY_FRACTION),
        "active_span_ms": float(report.get("active_span_ms", -1))
        >= observe_seconds * 1_000 * MINIMUM_ACTIVITY_FRACTION,
        "last_frame_age_ms": 0 <= float(report.get("last_frame_age_ms", -1))
        <= MAXIMUM_LAST_FRAME_AGE_MS,
    }
    invalid_activity = [
        name for name, passed in activity_requirements.items() if not passed
    ]
    if invalid_activity:
        raise ValueError(
            f"incomplete benchmark activity in {prefix.with_suffix('.json')}: "
            + ", ".join(invalid_activity)
        )
    if client == "swiftspice":
        validate_swift_renderer_evidence(report, prefix.with_suffix(".json"))
        validate_swift_video_evidence(
            report, video_codec, prefix.with_suffix(".json")
        )
    report.update(parse_time(prefix.with_suffix(".time.txt")))
    report["boot_epoch"] = boot_epoch
    report["requested_renderer"] = requested_renderer
    report["requested_video_codec"] = video_codec
    if "cpu_seconds" in report:
        report["cpu_seconds_per_frame"] = (
            float(report["cpu_seconds"]) / float(report["frames"])
        )
    if "observe_cpu_seconds" in report:
        report["observe_cpu_seconds_per_frame"] = (
            float(report["observe_cpu_seconds"]) / float(report["frames"])
        )
    return report


def percentile(sorted_values: list[float], fraction: float) -> float:
    index = round((len(sorted_values) - 1) * fraction)
    return sorted_values[index]


def bootstrap_median_ci(ratios: list[float], seed: int = 0) -> tuple[float, float, float]:
    generator = random.Random(seed)
    medians = []
    for _ in range(10_000):
        sample = [generator.choice(ratios) for _ in ratios]
        medians.append(statistics.median(sample))
    medians.sort()
    return (
        statistics.median(ratios),
        percentile(medians, 0.025),
        percentile(medians, 0.975),
    )


def analyze(directory: Path, expected_pairs: int | None = None) -> dict[str, object]:
    integrity_failures = directory / "integrity-failures.tsv"
    if integrity_failures.exists() and integrity_failures.read_text().strip():
        raise ValueError(f"recorded integrity failures in {integrity_failures}")
    run_numbers = sorted(
        int(match.group(1))
        for path in directory.glob("run-??-swiftspice.json")
        if (match := re.fullmatch(r"run-(\d+)-swiftspice\.json", path.name))
    )
    if not run_numbers:
        raise ValueError(f"no paired results found in {directory}")
    if expected_pairs is not None and run_numbers != list(range(1, expected_pairs + 1)):
        raise ValueError(
            f"expected complete runs 1...{expected_pairs}, found {run_numbers} in {directory}"
        )

    pairs = [
        (
            load_client(directory, run, "swiftspice"),
            load_client(directory, run, "spice-client-glib2"),
        )
        for run in run_numbers
    ]
    for run, (swift, reference) in zip(run_numbers, pairs, strict=True):
        if swift["boot_epoch"] != reference["boot_epoch"]:
            raise ValueError(
                f"boot epoch changed within pair {run}: "
                f"{swift['boot_epoch']} != {reference['boot_epoch']}"
            )
        if swift["requested_renderer"] != reference["requested_renderer"]:
            raise ValueError(
                f"renderer changed within pair {run}: "
                f"{swift['requested_renderer']} != {reference['requested_renderer']}"
            )
        if swift["requested_video_codec"] != reference["requested_video_codec"]:
            raise ValueError(
                f"video codec changed within pair {run}: "
                f"{swift['requested_video_codec']} != "
                f"{reference['requested_video_codec']}"
            )
    renderers = sorted({str(swift["requested_renderer"]) for swift, _ in pairs})
    if len(renderers) != 1:
        raise ValueError(f"mixed renderers in {directory}: {', '.join(renderers)}")
    renderer = renderers[0]
    video_codecs = sorted(
        {str(swift["requested_video_codec"]) for swift, _ in pairs}
    )
    if len(video_codecs) != 1:
        raise ValueError(
            f"mixed video codecs in {directory}: {', '.join(video_codecs)}"
        )
    video_codec = video_codecs[0]
    metrics: dict[str, object] = {}
    overall_pass = True
    for name, (direction, threshold) in METRICS.items():
        available = []
        invalid_runs = []
        for run, (swift, reference) in zip(run_numbers, pairs, strict=True):
            if (
                name not in swift
                or name not in reference
                or swift[name] is None
                or reference[name] is None
                or float(reference[name]) == 0
            ):
                invalid_runs.append(run)
                continue
            available.append((float(swift[name]), float(reference[name])))
        if invalid_runs:
            raise ValueError(
                f"required metric {name} is missing or unusable in pairs: "
                + ", ".join(str(run) for run in invalid_runs)
            )
        ratios = [swift / reference for swift, reference in available]
        median, lower, upper = bootstrap_median_ci(ratios)
        passed = lower >= threshold if direction == "higher" else upper <= threshold
        overall_pass = overall_pass and passed
        metrics[name] = {
            "direction": direction,
            "threshold": threshold,
            "paired_runs": len(ratios),
            "median_ratio": median,
            "ci95_lower": lower,
            "ci95_upper": upper,
            "passed": passed,
        }
    return {
        "renderer": renderer,
        "video_codec": video_codec,
        "paired_runs": len(pairs),
        "passed": overall_pass,
        "metrics": metrics,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--expected-pairs", type=int)
    args = parser.parse_args()
    if args.expected_pairs is not None and args.expected_pairs < 1:
        parser.error("--expected-pairs must be positive")
    report = analyze(args.directory, expected_pairs=args.expected_pairs)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"paired runs: {report['paired_runs']}")
        print("metric                 median ratio       95% CI      gate   result")
        for name, result in report["metrics"].items():
            gate = (
                f">= {result['threshold']:.2f}"
                if result["direction"] == "higher"
                else f"<= {result['threshold']:.2f}"
            )
            status = "PASS" if result["passed"] else "FAIL"
            print(
                f"{name:22} {result['median_ratio']:12.4f} "
                f"[{result['ci95_lower']:.4f}, {result['ci95_upper']:.4f}] "
                f"{gate:7} {status}"
            )
        print(f"overall: {'PASS' if report['passed'] else 'FAIL'}")
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
