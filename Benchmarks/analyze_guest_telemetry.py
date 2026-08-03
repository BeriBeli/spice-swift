#!/usr/bin/env python3
"""Validate RemoteRocky guest telemetry for direct renderer benchmark pairs."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path


RENDERERS = ("cpu-iosurface", "metal")
MARKER_EVENTS = {"start", "reset"}
TELEMETRY_EVENTS = MARKER_EVENTS | {"heartbeat"}
TELEMETRY_FIELDS = {
    "event",
    "generation",
    "frame_id",
    "monotonic_uptime_seconds",
    "pid",
    "boot_epoch",
}
MINIMUM_WINDOW_FRACTION = 0.8
MAXIMUM_HEARTBEAT_GAP_SECONDS = 5.0


def require_int(
    mapping: dict[str, object], name: str, path: Path, *, minimum: int | None = None
) -> int:
    value = mapping.get(name)
    if type(value) is not int or (minimum is not None and value < minimum):
        raise ValueError(f"missing or invalid {name} in {path}")
    return value


def require_boot_epoch(mapping: dict[str, object], path: Path) -> str:
    value = mapping.get("boot_epoch")
    if (
        not isinstance(value, str)
        or not value
        or any(character.isspace() for character in value)
    ):
        raise ValueError(f"missing or invalid boot_epoch in {path}")
    return value


def discover_metadata(
    result_directory: Path, expected_pairs: int, observe_seconds: int
) -> list[tuple[int, int, str, str]]:
    expected = {
        (pair, renderer)
        for pair in range(1, expected_pairs + 1)
        for renderer in RENDERERS
    }
    discovered: dict[tuple[int, str], Path] = {}
    pattern = re.compile(r"pair-(\d+)-(cpu-iosurface|metal)\.meta\.json")
    for path in result_directory.glob("pair-*.meta.json"):
        match = pattern.fullmatch(path.name)
        if match is None:
            raise ValueError(f"invalid direct renderer metadata name: {path}")
        pair = int(match.group(1))
        renderer = match.group(2)
        if path.name != f"pair-{pair:02d}-{renderer}.meta.json":
            raise ValueError(f"non-canonical direct renderer metadata name: {path}")
        identity = (pair, renderer)
        if identity in discovered:
            raise ValueError(
                f"duplicate direct renderer metadata for pair {pair} "
                f"renderer {renderer}: {path}"
            )
        discovered[identity] = path

    actual = set(discovered)
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        details = []
        if missing:
            details.append(f"missing={missing}")
        if unexpected:
            details.append(f"unexpected={unexpected}")
        raise ValueError(
            f"incomplete direct renderer metadata in {result_directory}: "
            + ", ".join(details)
        )

    samples = []
    for pair, renderer in sorted(expected):
        path = discovered[(pair, renderer)]
        metadata = json.loads(path.read_text())
        if not isinstance(metadata, dict):
            raise ValueError(f"metadata must contain a JSON object in {path}")
        if (
            metadata.get("client") != "swiftspice"
            or require_int(metadata, "pair", path, minimum=1) != pair
            or metadata.get("requested_renderer") != renderer
        ):
            raise ValueError(f"sample identity mismatch in {path}")
        if require_int(metadata, "observe_seconds", path, minimum=1) != observe_seconds:
            raise ValueError(f"observation duration mismatch in {path}")
        sample_order = require_int(metadata, "sample_order", path, minimum=1)
        if sample_order > 2:
            raise ValueError(f"invalid sample order in {path}")
        expected_order = RENDERERS if pair % 2 == 1 else tuple(reversed(RENDERERS))
        if expected_order[sample_order - 1] != renderer:
            raise ValueError(f"sample order mismatch in {path}")
        boot_epoch = require_boot_epoch(metadata, path)
        if metadata.get("boot_epoch_end") != boot_epoch:
            raise ValueError(f"boot epoch changed during sample in {path}")
        samples.append((pair, sample_order, renderer, boot_epoch))
    return sorted(samples, key=lambda sample: (sample[0], sample[1]))


def find_telemetry_path(
    telemetry_directory: Path, pair: int, renderer: str
) -> Path:
    suffixes = (
        f"-run-{pair:02d}-{renderer}-guest-telemetry.log",
        f"-direct-pair-{pair:02d}-{renderer}-guest-telemetry.log",
    )
    matches = sorted(
        {
            path
            for suffix in suffixes
            for path in telemetry_directory.rglob(f"*{suffix}")
            if path.is_file() and path.name.endswith(suffix)
        }
    )
    if not matches:
        raise ValueError(
            f"missing guest telemetry for pair {pair} renderer {renderer} "
            f"in {telemetry_directory}"
        )
    if len(matches) != 1:
        raise ValueError(
            f"duplicate guest telemetry for pair {pair} renderer {renderer}: "
            + ", ".join(str(path) for path in matches)
        )
    return matches[0]


def marker_event(line: str) -> str | None:
    if not line.startswith("PERF_GENERATOR "):
        return None
    for token in line.split()[1:]:
        if token.startswith("event="):
            event = token.removeprefix("event=")
            return event if event in MARKER_EVENTS else None
    return None


def parse_telemetry_line(line: str, path: Path, line_number: int) -> dict[str, object]:
    tokens = line.split()
    if not tokens or tokens[0] != "PERF_GENERATOR":
        raise ValueError(f"invalid guest telemetry line {line_number} in {path}")
    fields: dict[str, str] = {}
    for token in tokens[1:]:
        if "=" not in token:
            raise ValueError(f"invalid guest telemetry line {line_number} in {path}")
        name, value = token.split("=", maxsplit=1)
        if not name or not value or name in fields:
            raise ValueError(f"invalid guest telemetry line {line_number} in {path}")
        fields[name] = value
    if set(fields) != TELEMETRY_FIELDS:
        raise ValueError(
            f"invalid guest telemetry fields on line {line_number} in {path}"
        )

    event = fields["event"]
    if event not in TELEMETRY_EVENTS:
        raise ValueError(
            f"invalid guest telemetry event on line {line_number} in {path}"
        )
    try:
        generation = int(fields["generation"])
        frame_id = int(fields["frame_id"])
        uptime = float(fields["monotonic_uptime_seconds"])
        pid = int(fields["pid"])
    except ValueError as error:
        raise ValueError(
            f"invalid guest telemetry number on line {line_number} in {path}"
        ) from error
    if (
        generation < 0
        or frame_id < 0
        or pid < 1
        or not math.isfinite(uptime)
        or uptime < 0
    ):
        raise ValueError(
            f"invalid guest telemetry value on line {line_number} in {path}"
        )
    boot_epoch = fields["boot_epoch"]
    if not boot_epoch or any(character.isspace() for character in boot_epoch):
        raise ValueError(f"invalid guest boot epoch on line {line_number} in {path}")
    return {
        "event": event,
        "generation": generation,
        "frame_id": frame_id,
        "monotonic_uptime_seconds": uptime,
        "pid": pid,
        "boot_epoch": boot_epoch,
    }


def validate_telemetry(
    path: Path, expected_boot_epoch: str, observe_seconds: int
) -> dict[str, object]:
    lines = [
        (line_number, line.strip())
        for line_number, line in enumerate(path.read_text().splitlines(), start=1)
        if line.strip()
    ]
    marker_indexes = [
        index for index, (_, line) in enumerate(lines) if marker_event(line) is not None
    ]
    if not marker_indexes:
        raise ValueError(f"missing start/reset marker in {path}")

    marker_index = marker_indexes[-1]
    records = [
        parse_telemetry_line(line, path, line_number)
        for line_number, line in lines[marker_index:]
    ]
    if len(records) < 2:
        raise ValueError(f"incomplete guest telemetry samples in {path}")
    if records[0]["event"] not in MARKER_EVENTS or records[0]["frame_id"] != 0:
        raise ValueError(f"invalid final start/reset marker in {path}")
    if any(record["event"] != "heartbeat" for record in records[1:]):
        raise ValueError(f"unexpected marker after final start/reset marker in {path}")

    boot_epochs = {record["boot_epoch"] for record in records}
    if boot_epochs != {expected_boot_epoch}:
        raise ValueError(
            f"guest boot epoch mismatch in {path}: "
            f"expected {expected_boot_epoch}, found {sorted(boot_epochs)}"
        )
    generations = {record["generation"] for record in records}
    if len(generations) != 1:
        raise ValueError(f"mixed guest generations after marker in {path}")
    pids = {record["pid"] for record in records}
    if len(pids) != 1:
        raise ValueError(f"mixed guest generator PIDs after marker in {path}")

    heartbeat_gaps = []
    for previous, current in zip(records, records[1:]):
        if current["frame_id"] <= previous["frame_id"]:
            raise ValueError(f"non-monotonic guest frame_id after marker in {path}")
        heartbeat_gap = float(current["monotonic_uptime_seconds"]) - float(
            previous["monotonic_uptime_seconds"]
        )
        if heartbeat_gap <= 0:
            raise ValueError(f"non-monotonic guest uptime after marker in {path}")
        heartbeat_gaps.append(heartbeat_gap)

    maximum_heartbeat_gap = max(heartbeat_gaps)
    if maximum_heartbeat_gap > MAXIMUM_HEARTBEAT_GAP_SECONDS:
        raise ValueError(
            f"guest telemetry heartbeat gap in {path}: "
            f"gap={maximum_heartbeat_gap:.3f}s, "
            f"maximum={MAXIMUM_HEARTBEAT_GAP_SECONDS:.3f}s"
        )

    first_uptime = float(records[0]["monotonic_uptime_seconds"])
    last_uptime = float(records[-1]["monotonic_uptime_seconds"])
    window_span_seconds = last_uptime - first_uptime
    minimum_span = observe_seconds * MINIMUM_WINDOW_FRACTION
    if window_span_seconds < minimum_span:
        raise ValueError(
            f"incomplete guest telemetry window in {path}: "
            f"span={window_span_seconds:.3f}s, required={minimum_span:.3f}s"
        )
    return {
        "records": len(records),
        "window_span_seconds": window_span_seconds,
        "maximum_heartbeat_gap_seconds": maximum_heartbeat_gap,
        "generation": int(records[0]["generation"]),
        "pid": int(records[0]["pid"]),
        "first_uptime_seconds": first_uptime,
        "last_uptime_seconds": last_uptime,
    }


def analyze(
    result_directory: Path,
    telemetry_directory: Path,
    expected_pairs: int,
    observe_seconds: int,
) -> dict[str, object]:
    if expected_pairs < 1:
        raise ValueError("expected_pairs must be positive")
    if observe_seconds < 1:
        raise ValueError("observe_seconds must be positive")
    if not result_directory.is_dir():
        raise ValueError(f"result directory does not exist: {result_directory}")
    if not telemetry_directory.is_dir():
        raise ValueError(f"telemetry directory does not exist: {telemetry_directory}")

    samples = discover_metadata(result_directory, expected_pairs, observe_seconds)
    summaries = []
    telemetry_paths: set[Path] = set()
    boot_epochs = set()
    for pair, _sample_order, renderer, boot_epoch in samples:
        path = find_telemetry_path(telemetry_directory, pair, renderer)
        if path in telemetry_paths:
            raise ValueError(f"guest telemetry reused by multiple samples: {path}")
        telemetry_paths.add(path)
        boot_epochs.add(boot_epoch)
        summaries.append(validate_telemetry(path, boot_epoch, observe_seconds))

    if len(boot_epochs) != 1:
        raise ValueError("mixed guest boot epochs across direct renderer batch")
    generator_pids = {int(summary["pid"]) for summary in summaries}
    if len(generator_pids) != 1:
        raise ValueError("mixed guest generator PIDs across direct renderer batch")
    for previous, current in zip(summaries, summaries[1:]):
        if int(current["generation"]) != int(previous["generation"]) + 1:
            raise ValueError("guest generation did not advance once per sample")
        if float(current["first_uptime_seconds"]) <= float(
            previous["last_uptime_seconds"]
        ):
            raise ValueError("guest telemetry sample windows overlap or regress")

    return {
        "passed": True,
        "expected_pairs": expected_pairs,
        "observe_seconds": observe_seconds,
        "validated_samples": len(summaries),
        "telemetry_records": sum(int(summary["records"]) for summary in summaries),
        "minimum_records_per_sample": min(
            int(summary["records"]) for summary in summaries
        ),
        "minimum_window_span_seconds": round(
            min(float(summary["window_span_seconds"]) for summary in summaries), 3
        ),
        "minimum_window_fraction": MINIMUM_WINDOW_FRACTION,
        "maximum_heartbeat_gap_seconds": round(
            max(
                float(summary["maximum_heartbeat_gap_seconds"])
                for summary in summaries
            ),
            3,
        ),
        "guest_generation_start": int(summaries[0]["generation"]),
        "guest_generation_end": int(summaries[-1]["generation"]),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate guest telemetry for direct renderer benchmark pairs."
    )
    parser.add_argument("result_directory", type=Path)
    parser.add_argument("telemetry_directory", type=Path)
    parser.add_argument("--expected-pairs", type=int, required=True)
    parser.add_argument("--observe-seconds", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        report = analyze(
            args.result_directory,
            args.telemetry_directory,
            args.expected_pairs,
            args.observe_seconds,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(
            json.dumps({"passed": False, "error": str(error)}, sort_keys=True),
            file=sys.stderr,
        )
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
