#!/usr/bin/env python3
"""Analyze direct cpu-iosurface versus metal SwiftSpice benchmark pairs."""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import re
from pathlib import Path
from types import ModuleType


BASELINE_RENDERER = "cpu-iosurface"
CANDIDATE_RENDERER = "metal"
COMPARISON = f"{CANDIDATE_RENDERER}/{BASELINE_RENDERER}"
BYTES_PER_PIXEL = 4
MAX_SIGNED_64_BIT_INTEGER = (1 << 63) - 1
SUPPORTED_RESET_SOURCES = {"reset-script", "hook"}


def load_common_analyzer() -> ModuleType:
    path = Path(__file__).with_name("analyze.py")
    spec = importlib.util.spec_from_file_location(
        "swiftspice_live_benchmark_analyze", path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load shared benchmark analyzer from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COMMON = load_common_analyzer()
METRICS = COMMON.METRICS


def parse_resolution(value: object, path: Path) -> tuple[str, int, int]:
    if not isinstance(value, str):
        raise ValueError(f"missing or invalid resolution in {path}")
    match = re.fullmatch(r"([1-9][0-9]*)x([1-9][0-9]*)", value)
    if match is None:
        raise ValueError(f"missing or invalid resolution in {path}")
    return value, int(match.group(1)), int(match.group(2))


def require_int(
    mapping: dict[str, object], name: str, path: Path, *, minimum: int | None = None
) -> int:
    value = mapping.get(name)
    if type(value) is not int or (minimum is not None and value < minimum):
        raise ValueError(f"missing or invalid {name} in {path}")
    return value


def require_number(mapping: dict[str, object], name: str, path: Path) -> float:
    value = mapping.get(name)
    if type(value) not in {int, float}:
        raise ValueError(f"missing or invalid {name} in {path}")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"missing or invalid {name} in {path}")
    return number


def validate_activity(
    report: dict[str, object], observe_seconds: int, path: Path
) -> tuple[int, int]:
    frames = require_int(report, "frames", path, minimum=2)
    frame_bytes = require_int(report, "frame_bytes", path, minimum=1)
    expected_buckets = require_int(report, "expected_time_buckets", path)
    active_buckets = require_int(report, "active_time_buckets", path)
    active_span_ms = require_number(report, "active_span_ms", path)
    last_frame_age_ms = require_number(report, "last_frame_age_ms", path)
    requirements = {
        "expected_time_buckets": expected_buckets
        == COMMON.EXPECTED_ACTIVITY_BUCKETS,
        "active_time_buckets": active_buckets
        >= int(
            COMMON.EXPECTED_ACTIVITY_BUCKETS * COMMON.MINIMUM_ACTIVITY_FRACTION
        ),
        "active_span_ms": active_span_ms
        >= observe_seconds * 1_000 * COMMON.MINIMUM_ACTIVITY_FRACTION,
        "last_frame_age_ms": 0
        <= last_frame_age_ms
        <= COMMON.MAXIMUM_LAST_FRAME_AGE_MS,
    }
    invalid = [name for name, passed in requirements.items() if not passed]
    if invalid:
        raise ValueError(
            f"incomplete benchmark activity in {path}: " + ", ".join(invalid)
        )
    return frames, frame_bytes


def load_renderer(
    directory: Path, pair: int, renderer: str
) -> dict[str, object]:
    if renderer not in {BASELINE_RENDERER, CANDIDATE_RENDERER}:
        raise ValueError(f"unsupported renderer role: {renderer}")
    prefix = directory / f"pair-{pair:02d}-{renderer}"
    report_path = prefix.with_suffix(".json")
    metadata_path = prefix.with_suffix(".meta.json")
    report = json.loads(report_path.read_text())
    metadata = json.loads(metadata_path.read_text())
    if not isinstance(report, dict) or not isinstance(metadata, dict):
        raise ValueError(f"sample must contain JSON objects at {prefix}")

    if (
        metadata.get("client") != "swiftspice"
        or require_int(metadata, "pair", metadata_path, minimum=1) != pair
        or metadata.get("requested_renderer") != renderer
    ):
        raise ValueError(f"sample identity mismatch in {metadata_path}")
    if report.get("client") != "swiftspice":
        raise ValueError(f"client report identity mismatch in {report_path}")
    if report.get("renderer") != renderer:
        raise ValueError(f"renderer metadata mismatch in {metadata_path}")
    if require_int(metadata, "exit_code", metadata_path) != 0:
        raise ValueError(f"client exited unsuccessfully in {metadata_path}")
    if require_int(metadata, "hook_after_exit_code", metadata_path) != 0:
        raise ValueError(f"after hook exited unsuccessfully in {metadata_path}")

    sample_order = require_int(metadata, "sample_order", metadata_path, minimum=1)
    if sample_order > 2:
        raise ValueError(f"missing or invalid sample_order in {metadata_path}")
    reset_source = metadata.get("deterministic_reset_source")
    if reset_source not in SUPPORTED_RESET_SOURCES:
        raise ValueError(f"missing deterministic reset evidence in {metadata_path}")
    boot_epoch = metadata.get("boot_epoch")
    if (
        not isinstance(boot_epoch, str)
        or not boot_epoch
        or "\n" in boot_epoch
        or "\r" in boot_epoch
    ):
        raise ValueError(f"missing boot epoch in {metadata_path}")
    boot_epoch_end = metadata.get("boot_epoch_end")
    if (
        not isinstance(boot_epoch_end, str)
        or not boot_epoch_end
        or "\n" in boot_epoch_end
        or "\r" in boot_epoch_end
        or require_int(metadata, "boot_epoch_end_exit_code", metadata_path) != 0
    ):
        raise ValueError(f"missing end boot epoch in {metadata_path}")
    if boot_epoch_end != boot_epoch:
        raise ValueError(
            f"boot epoch changed during sample in {metadata_path}: "
            f"{boot_epoch} != {boot_epoch_end}"
        )
    video_codec = metadata.get("video_codec")
    if video_codec not in COMMON.SUPPORTED_VIDEO_CODECS:
        raise ValueError(f"missing or invalid video codec in {metadata_path}")
    resolution, width, height = parse_resolution(
        metadata.get("resolution"), metadata_path
    )

    observe_seconds = require_int(report, "observe_seconds", report_path, minimum=1)
    if (
        require_int(metadata, "observe_seconds", metadata_path, minimum=1)
        != observe_seconds
    ):
        raise ValueError(f"observation duration mismatch in {metadata_path}")
    frames, frame_bytes = validate_activity(report, observe_seconds, report_path)
    expected_frame_bytes = width * height * BYTES_PER_PIXEL
    expected_total_bytes = frames * expected_frame_bytes
    if (
        expected_frame_bytes > MAX_SIGNED_64_BIT_INTEGER
        or expected_total_bytes > MAX_SIGNED_64_BIT_INTEGER
    ):
        raise ValueError(f"resolution evidence overflow in {metadata_path}")
    if frame_bytes % frames != 0:
        raise ValueError(
            f"resolution evidence is not frame-aligned in {report_path}: "
            f"frame_bytes={frame_bytes}, frames={frames}"
        )
    if frame_bytes != expected_total_bytes:
        raise ValueError(
            f"resolution evidence mismatch in {report_path}: "
            f"frame_bytes={frame_bytes}, expected={frames}*{width}*{height}*"
            f"{BYTES_PER_PIXEL}={expected_total_bytes}"
        )

    COMMON.validate_swift_renderer_evidence(report, video_codec, report_path)
    COMMON.validate_swift_video_evidence(report, video_codec, report_path)
    direct_requirements = (
        {"cpu_materializations": 0}
        if renderer == BASELINE_RENDERER
        else {"cpu_scaled_copy_operations": 0}
    )
    invalid_direct_evidence = [
        name
        for name, expected in direct_requirements.items()
        if name not in report
        or type(report[name]) is not type(expected)
        or report[name] != expected
    ]
    if invalid_direct_evidence:
        raise ValueError(
            f"invalid direct {renderer} renderer evidence in {report_path}: "
            + ", ".join(invalid_direct_evidence)
        )
    report.update(COMMON.parse_time(prefix.with_suffix(".time.txt")))
    report["boot_epoch"] = boot_epoch
    report["boot_epoch_end"] = boot_epoch_end
    report["requested_renderer"] = renderer
    report["requested_video_codec"] = video_codec
    report["requested_resolution"] = resolution
    report["sample_order"] = sample_order
    report["deterministic_reset_source"] = reset_source
    report["frame_bytes_per_frame"] = expected_frame_bytes
    if "cpu_seconds" in report:
        report["cpu_seconds_per_frame"] = float(report["cpu_seconds"]) / frames
    if "observe_cpu_seconds" in report:
        report["observe_cpu_seconds_per_frame"] = (
            float(report["observe_cpu_seconds"]) / frames
        )
    return report


def discover_pairs(directory: Path) -> list[int]:
    run_sets = []
    for renderer in (BASELINE_RENDERER, CANDIDATE_RENDERER):
        pattern = re.compile(rf"pair-(\d+)-{re.escape(renderer)}\.json")
        renderer_pairs = set()
        for path in directory.glob(f"pair-*-{renderer}.json"):
            match = pattern.fullmatch(path.name)
            if match is None:
                raise ValueError(f"invalid direct renderer sample name: {path}")
            pair = int(match.group(1))
            if path.name != f"pair-{pair:02d}-{renderer}.json":
                raise ValueError(f"non-canonical direct renderer sample name: {path}")
            if pair in renderer_pairs:
                raise ValueError(f"duplicate direct renderer pair {pair}: {path}")
            renderer_pairs.add(pair)
        run_sets.append(renderer_pairs)
    if not run_sets[0] and not run_sets[1]:
        raise ValueError(f"no direct renderer pairs found in {directory}")
    if run_sets[0] != run_sets[1]:
        raise ValueError(
            "incomplete direct renderer pairs in "
            f"{directory}: {BASELINE_RENDERER}={sorted(run_sets[0])}, "
            f"{CANDIDATE_RENDERER}={sorted(run_sets[1])}"
        )
    pair_numbers = sorted(run_sets[0])
    if pair_numbers != list(range(1, pair_numbers[-1] + 1)):
        raise ValueError(
            f"non-contiguous direct renderer pairs in {directory}: {pair_numbers}"
        )
    return pair_numbers


def require_single_value(
    pairs: list[tuple[dict[str, object], dict[str, object]]],
    field: str,
    label: str,
    directory: Path,
) -> object:
    values = {sample[field] for pair in pairs for sample in pair}
    if len(values) != 1:
        rendered = ", ".join(sorted(str(value) for value in values))
        raise ValueError(f"mixed {label} in {directory}: {rendered}")
    return next(iter(values))


def analyze(directory: Path, expected_pairs: int | None = None) -> dict[str, object]:
    integrity_failures = directory / "integrity-failures.tsv"
    if integrity_failures.exists() and integrity_failures.read_text().strip():
        raise ValueError(f"recorded integrity failures in {integrity_failures}")
    pair_numbers = discover_pairs(directory)
    if expected_pairs is not None and pair_numbers != list(
        range(1, expected_pairs + 1)
    ):
        raise ValueError(
            f"expected complete pairs 1...{expected_pairs}, found {pair_numbers} "
            f"in {directory}"
        )

    pairs = [
        (
            load_renderer(directory, pair, BASELINE_RENDERER),
            load_renderer(directory, pair, CANDIDATE_RENDERER),
        )
        for pair in pair_numbers
    ]
    for pair_number, (baseline, candidate) in zip(
        pair_numbers, pairs, strict=True
    ):
        expected_order = (
            (BASELINE_RENDERER, CANDIDATE_RENDERER)
            if pair_number % 2 == 1
            else (CANDIDATE_RENDERER, BASELINE_RENDERER)
        )
        sample_orders = {
            int(baseline["sample_order"]),
            int(candidate["sample_order"]),
        }
        if sample_orders != {1, 2}:
            raise ValueError(
                f"invalid sample ordinals in pair {pair_number}: "
                f"{sorted(sample_orders)}"
            )
        actual_order = tuple(
            renderer
            for _, renderer in sorted(
                (
                    (int(baseline["sample_order"]), BASELINE_RENDERER),
                    (int(candidate["sample_order"]), CANDIDATE_RENDERER),
                )
            )
        )
        if actual_order != expected_order:
            raise ValueError(
                f"invalid alternating renderer order in pair {pair_number}: "
                + " -> ".join(actual_order)
            )

    boot_epoch = require_single_value(pairs, "boot_epoch", "boot epochs", directory)
    video_codec = require_single_value(
        pairs, "requested_video_codec", "video codecs", directory
    )
    resolution = require_single_value(
        pairs, "requested_resolution", "resolutions", directory
    )
    frame_bytes_per_frame = require_single_value(
        pairs, "frame_bytes_per_frame", "frame byte footprints", directory
    )
    observe_seconds = require_single_value(
        pairs, "observe_seconds", "observation durations", directory
    )
    reset_source = require_single_value(
        pairs, "deterministic_reset_source", "reset sources", directory
    )

    metrics: dict[str, object] = {}
    overall_pass = True
    for name, (direction, threshold) in METRICS.items():
        ratios = []
        invalid_pairs = []
        for pair_number, (baseline, candidate) in zip(
            pair_numbers, pairs, strict=True
        ):
            baseline_value = baseline.get(name)
            candidate_value = candidate.get(name)
            if (
                type(baseline_value) not in {int, float}
                or type(candidate_value) not in {int, float}
                or not math.isfinite(float(baseline_value))
                or not math.isfinite(float(candidate_value))
                or float(baseline_value) <= 0
                or float(candidate_value) <= 0
            ):
                invalid_pairs.append(pair_number)
                continue
            ratios.append(float(candidate_value) / float(baseline_value))
        if invalid_pairs:
            raise ValueError(
                f"required metric {name} is missing or unusable in pairs: "
                + ", ".join(str(pair) for pair in invalid_pairs)
            )
        median, lower, upper = COMMON.bootstrap_median_ci(ratios)
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
        "comparison": COMPARISON,
        "baseline_renderer": BASELINE_RENDERER,
        "candidate_renderer": CANDIDATE_RENDERER,
        "boot_epoch": boot_epoch,
        "video_codec": video_codec,
        "resolution": resolution,
        "frame_bytes_per_frame": frame_bytes_per_frame,
        "observe_seconds": observe_seconds,
        "deterministic_reset_source": reset_source,
        "paired_runs": len(pairs),
        "passed": overall_pass,
        "metrics": metrics,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze paired Metal / cpu-iosurface SwiftSpice results."
    )
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
        print(f"comparison: {report['comparison']}")
        print(f"paired runs: {report['paired_runs']}")
        print(f"boot epoch: {report['boot_epoch']}")
        print(f"video codec: {report['video_codec']}")
        print(f"resolution: {report['resolution']}")
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
