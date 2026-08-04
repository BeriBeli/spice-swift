from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
TEST_RESAMPLES = 500
sys.path.insert(0, str(REPOSITORY / "Benchmarks"))

import analyze_cpu_saturation as analyzer  # noqa: E402
import run_cpu_saturation_ab as runner  # noqa: E402


def render_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_jsonl(path: Path, values: list[dict[str, object]]) -> None:
    path.write_text(
        "".join(json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n" for value in values),
        encoding="utf-8",
    )


def make_sample(
    resolution: str,
    frames: int,
    *,
    ingest_cpu_per_command: int,
    resident_bytes: int,
) -> dict[str, object]:
    commands = frames * 57
    width, height = (1_280, 720) if resolution == "720p" else (3_840, 2_160)
    surface_bytes = width * height * 4
    ingest_cpu = ingest_cpu_per_command * commands
    end_to_end_per_command = ingest_cpu_per_command + 10
    end_to_end_cpu = end_to_end_per_command * commands
    legacy_per_command = ingest_cpu_per_command + 20
    legacy_cpu = legacy_per_command * commands
    sample: dict[str, object] = {key: 0 for key in analyzer.SAMPLE_KEYS}
    sample.update(
        {
            "schema_version": 2,
            "backend": "cpu-iosurface",
            "input_mode": "saturation",
            "resolution": resolution,
            "width": width,
            "height": height,
            "frames": frames,
            "commands": commands,
            "benchmark_process_id": 20_001,
            "diagnostics_enabled": False,
            "commands_per_frame": 57,
            "bitmap_width": 32,
            "bitmap_height": 25,
            "bitmap_payload_bytes": 3_200,
            "publisher_interval_nanoseconds": 600_000_000_000,
            "ingest_wall_nanoseconds": ingest_cpu * 2,
            "ingest_process_cpu_nanoseconds": ingest_cpu,
            "ingest_cpu_nanoseconds_per_frame": ingest_cpu // frames,
            "ingest_cpu_nanoseconds_per_command": ingest_cpu_per_command,
            "end_to_end_wall_nanoseconds": end_to_end_cpu * 2,
            "end_to_end_process_cpu_nanoseconds": end_to_end_cpu,
            "end_to_end_cpu_nanoseconds_per_frame": end_to_end_cpu // frames,
            "end_to_end_cpu_nanoseconds_per_command": end_to_end_per_command,
            "wall_nanoseconds": legacy_cpu * 2,
            "process_cpu_nanoseconds": legacy_cpu,
            "cpu_nanoseconds_per_frame": legacy_cpu // frames,
            "cpu_nanoseconds_per_command": legacy_per_command,
            "cpu_nanoseconds_per_published_frame": legacy_cpu,
            "resident_bytes": resident_bytes,
            "peak_resident_bytes": resident_bytes + 1_000_000,
            "published_fps_milli": 1,
            "publisher_p95_interval_nanoseconds": 0,
            "last_published_revision": commands,
            "publisher_submissions": commands,
            "publisher_snapshot_attempts": 1,
            "publisher_emitted_frames": 1,
            "publisher_stale_snapshots": 0,
            "publisher_pending_evictions": 0,
            "publisher_pending_surfaces": 0,
            "damage_operations": commands,
            "damage_bytes": commands * 3_200,
            "damage_rectangles_before_merge": commands,
            "damage_rectangles_after_merge": 1,
            "full_damage_by_new_slot": 1,
            "snapshots": 1,
            "full_frame_copy_bytes": surface_bytes,
            "partial_frame_copy_bytes": 0,
            "snapshot_catch_up_cpu_copy_bytes": surface_bytes,
            "cpu_materializations": 0,
            "cpu_materialization_bytes": 0,
            "pool_exhaustions": 0,
            "in_flight_leases": 1,
            "revisioned_backing_enabled": True,
            "revisioned_allocated_frames": 1,
            "revisioned_allocated_bytes": surface_bytes,
            "recommended_maximum_working_set_size": 1_000_000_000,
            "current_metal_allocated_size": 0,
            "gpu_copy_bytes": 0,
            "gpu_errors": 0,
            "compositor_errors": 0,
            "native_video_frames": 0,
            "native_video_fallbacks": 0,
            "revisioned_snapshot_reuses": 0,
            "revisioned_snapshot_uploads": 1,
            "data_backend_snapshots": 0,
            "revisioned_snapshot_fallbacks": 0,
            "unified_backing_disables": 0,
        }
    )
    return sample


class EvidenceFixture:
    def __init__(self, directory: Path, *, frames: int = analyzer.FORMAL_FRAMES) -> None:
        self.directory = directory
        self.frames = frames
        self.logs = directory / "logs"
        self.logs.mkdir(parents=True)
        self.baseline_commit = "a" * 40
        self.optimized_commit = "b" * 40
        self.harness_sha = "c" * 64
        self.records: list[dict[str, object]] = []

    def log_evidence(self, name: str, payload: bytes) -> dict[str, object]:
        path = self.logs / name
        path.write_bytes(payload)
        return analyzer.file_evidence(path)

    def add_record(
        self,
        *,
        phase: str,
        resolution: str,
        label: str,
        pair: int | None,
        order: str | None,
        sequence: int | None,
    ) -> None:
        run_index = len(self.records) + 1
        start = datetime(2026, 8, 4, tzinfo=timezone.utc) + timedelta(seconds=run_index * 2)
        per_command = 100 + (pair or 0) if label == "baseline" else 90 + (pair or 0)
        rss = 100_000_000 + (pair or 0) if label == "baseline" else 101_000_000 + (pair or 0)
        command = [
            "swift",
            "test",
            "-c",
            "release",
            "--scratch-path",
            f"/tmp/{label}",
            "--skip-build",
            "--disable-sandbox",
            "--filter",
            "CPUHotPathBenchmarkTests",
        ]
        sample = make_sample(
            resolution,
            self.frames,
            ingest_cpu_per_command=per_command,
            resident_bytes=rss,
        )
        retained_output = (
            b"Swift Testing output\n"
            + json.dumps(sample, separators=(",", ":"), sort_keys=True).encode()
            + b"\n"
        )
        self.records.append(
            {
                "schema_version": 2,
                "status": "succeeded",
                "run_index": run_index,
                "phase": phase,
                "resolution": resolution,
                "label": label,
                "commit": self.baseline_commit if label == "baseline" else self.optimized_commit,
                "harness_sha256": self.harness_sha,
                "pair": pair,
                "order": order,
                "sequence": sequence,
                "started_at_utc": render_utc(start),
                "finished_at_utc": render_utc(start + timedelta(seconds=1)),
                "exit_code": 0,
                "sample": sample,
                "execution": {
                    "scope": "host-outside-codex-sandbox",
                    "fresh_process": True,
                    "launcher_process_id": 10_000 + run_index,
                    "build_configuration": "release",
                    "command": command,
                    "environment": {
                        "SWIFTSPICE_CPU_HOTPATH_BENCHMARK": "1",
                        "SWIFTSPICE_CPU_HOTPATH_BACKEND": "cpu-iosurface",
                        "SWIFTSPICE_CPU_HOTPATH_INPUT_MODE": "saturation",
                        "SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS": "0",
                        "SWIFTSPICE_CPU_HOTPATH_RESOLUTION": resolution,
                        "SWIFTSPICE_CPU_HOTPATH_FRAMES": str(self.frames),
                    },
                },
                "log": self.log_evidence(
                    f"attempt-{run_index:03d}.log", retained_output
                ),
                "failure": None,
            }
        )

    def write(self) -> None:
        for resolution, label in runner.WARMUP_PLAN:
            self.add_record(
                phase="discarded-warmup",
                resolution=resolution,
                label=label,
                pair=None,
                order=None,
                sequence=None,
            )
        for resolution in analyzer.RESOLUTIONS:
            for pair in range(1, analyzer.PAIR_COUNT + 1):
                order, labels = analyzer.expected_formal_order(pair)
                for sequence, label in enumerate(labels, start=1):
                    self.add_record(
                        phase="formal",
                        resolution=resolution,
                        label=label,
                        pair=pair,
                        order=order,
                        sequence=sequence,
                    )

        build_logs = {
            label: self.log_evidence(f"build-{label}.log", b"build ok\n")
            for label in ("baseline", "optimized")
        }
        tools_directory = self.directory / "tools"
        tools_directory.mkdir()
        runner_bytes = (REPOSITORY / "Benchmarks" / "run_cpu_saturation_ab.py").read_bytes()
        analyzer_bytes = (REPOSITORY / "Benchmarks" / "analyze_cpu_saturation.py").read_bytes()
        (tools_directory / "run_cpu_saturation_ab.py").write_bytes(runner_bytes)
        (tools_directory / "analyze_cpu_saturation.py").write_bytes(analyzer_bytes)
        metadata = {
            "schema_version": 2,
            "protocol": analyzer.PROTOCOL,
            "status": "complete",
            "run_window_utc": {
                "started": self.records[0]["started_at_utc"],
                "finished": self.records[-1]["finished_at_utc"],
            },
            "host": {
                "system": "Darwin",
                "machine": "arm64",
                "hardware_model": "Mac16,8",
                "cpu_brand": "Apple M4 Pro",
                "boot_epoch_seconds": 1_775_171_600,
                "boot_time_utc": "2026-04-02T23:13:20.000Z",
                "collected_at_utc": "2026-08-03T23:59:00.000Z",
                "os_version": "26.6",
                "os_build": "25G72",
                "swift": "Swift 6.3.3",
                "xcode": "Xcode 26.6",
            },
            "provenance": {
                "baseline_commit": self.baseline_commit,
                "optimized_commit": self.optimized_commit,
                "harness_path": "Tests/SpiceCoreTests/CPUHotPathBenchmarkTests.swift",
                "common_harness_sha256": self.harness_sha,
                "tool_commit": "f" * 40,
                "tool_files": {
                    "runner": {
                        "repository_path": "Benchmarks/run_cpu_saturation_ab.py",
                        "evidence_path": "tools/run_cpu_saturation_ab.py",
                        "sha256": analyzer.file_evidence(
                            tools_directory / "run_cpu_saturation_ab.py"
                        )["sha256"],
                    },
                    "analyzer": {
                        "repository_path": "Benchmarks/analyze_cpu_saturation.py",
                        "evidence_path": "tools/analyze_cpu_saturation.py",
                        "sha256": analyzer.file_evidence(
                            tools_directory / "analyze_cpu_saturation.py"
                        )["sha256"],
                    },
                },
            },
            "workload": {
                "backend": "cpu-iosurface",
                "input_mode": "saturation",
                "diagnostics_enabled": False,
                "resolutions": list(analyzer.RESOLUTIONS),
                "frames": self.frames,
                "commands_per_frame": 57,
                "warmup_attempts": analyzer.WARMUP_COUNT,
                "formal_attempts": analyzer.FORMAL_COUNT,
                "pairs_per_resolution": analyzer.PAIR_COUNT,
                "process_model": "one fresh Release swift-test process per attempt",
            },
            "statistics": {
                "paired_ratio": "optimized / baseline",
                "primary_metric": analyzer.PRIMARY_METRIC,
                "secondary_metrics": list(analyzer.SECONDARY_METRICS),
                "estimator": "median of paired ratios",
                "bootstrap": "deterministic percentile bootstrap",
                "resamples": analyzer.RESAMPLES,
                "seeds": analyzer.SEEDS,
            },
            "execution": {
                "scope": "host-outside-codex-sandbox",
                "host_execution_confirmed": True,
                "sample_timeout_seconds": 180,
            },
            "builds": [
                {
                    "label": label,
                    "commit": self.baseline_commit if label == "baseline" else self.optimized_commit,
                    "exit_code": 0,
                    "command": ["swift", "test"],
                    "log": build_logs[label],
                }
                for label in ("baseline", "optimized")
            ],
        }
        write_json(self.directory / "metadata.json", metadata)
        write_jsonl(self.directory / "attempts.jsonl", self.records)
        write_jsonl(self.directory / "warmups.jsonl", self.records[:4])
        write_jsonl(self.directory / "formal_720p.jsonl", self.records[4:24])
        write_jsonl(self.directory / "formal_4k.jsonl", self.records[24:44])
        statistics = analyzer.analyze(
            self.directory,
            resamples=TEST_RESAMPLES,
            verify_manifest=False,
            internal_inputs_only=True,
        )
        write_json(self.directory / "stats.json", statistics)
        self.write_manifest()

    def write_manifest(self) -> None:
        paths = sorted(
            path
            for path in self.directory.rglob("*")
            if path.is_file() and path.name != "SHA256SUMS"
        )
        lines = [
            f"{analyzer.file_evidence(path)['sha256']}  "
            f"{path.relative_to(self.directory).as_posix()}"
            for path in paths
        ]
        (self.directory / "SHA256SUMS").write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )


class AnalyzeCPUSaturationTests(unittest.TestCase):
    def test_valid_evidence_uses_ingest_cpu_as_primary_and_retains_all_attempts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            EvidenceFixture(directory).write()
            result = analyzer.analyze(directory, resamples=TEST_RESAMPLES)

            self.assertEqual(result["primary_metric"], "ingest_cpu_nanoseconds_per_command")
            self.assertEqual(result["attempt_audit"]["attempts"], 44)
            self.assertEqual(result["attempt_audit"]["formal"], 40)
            for resolution_key in ("resolution_720p", "resolution_4k"):
                primary = result[resolution_key]["rows"][0]
                self.assertEqual(primary["role"], "primary")
                self.assertEqual(primary["metric"], analyzer.PRIMARY_METRIC)
                self.assertEqual(primary["outcome"], "decrease-detected")
                self.assertEqual(len(primary["paired_ratios"]), 10)

    def test_sample_rejects_non_saturation_and_any_fallback(self) -> None:
        sample = make_sample("720p", 100, ingest_cpu_per_command=100, resident_bytes=100_000_000)
        paced = copy.deepcopy(sample)
        paced["input_mode"] = "paced"
        with self.assertRaisesRegex(analyzer.EvidenceError, "wrong input mode"):
            analyzer.validate_sample(paced, "720p", 100, "sample")

        fallback = copy.deepcopy(sample)
        fallback["revisioned_snapshot_fallbacks"] = 1
        with self.assertRaisesRegex(analyzer.EvidenceError, "revisioned_snapshot_fallbacks"):
            analyzer.validate_sample(fallback, "720p", 100, "sample")

    def test_analyzer_rejects_broken_ab_ba_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = EvidenceFixture(directory)
            fixture.write()
            fixture.records[4]["order"] = "optimized-then-baseline"
            write_jsonl(directory / "attempts.jsonl", fixture.records)
            write_jsonl(directory / "formal_720p.jsonl", fixture.records[4:24])
            fixture.write_manifest()
            with self.assertRaisesRegex(analyzer.EvidenceError, "wrong order annotation"):
                analyzer.analyze(directory, resamples=100)

    def test_analyzer_rejects_failed_retained_attempt_instead_of_replacing_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = EvidenceFixture(directory)
            fixture.write()
            fixture.records[10]["status"] = "failed"
            fixture.records[10]["failure"] = "synthetic failure"
            fixture.records[10]["sample"] = None
            write_jsonl(directory / "attempts.jsonl", fixture.records)
            write_jsonl(directory / "formal_720p.jsonl", fixture.records[4:24])
            fixture.write_manifest()
            with self.assertRaisesRegex(analyzer.EvidenceError, "retained attempt failed"):
                analyzer.analyze(directory, resamples=100)

    def test_analyzer_rejects_record_sample_that_differs_from_retained_log(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = EvidenceFixture(directory)
            fixture.write()
            fixture.records[4]["sample"]["resident_bytes"] += 1
            write_jsonl(directory / "attempts.jsonl", fixture.records)
            write_jsonl(directory / "formal_720p.jsonl", fixture.records[4:24])
            fixture.write_manifest()
            with self.assertRaisesRegex(
                analyzer.EvidenceError, "retained log sample differs from record.sample"
            ):
                analyzer.analyze(directory, resamples=100)

    def test_analyzer_rejects_duplicate_sample_in_retained_log(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = EvidenceFixture(directory)
            fixture.write()
            record = fixture.records[4]
            log_path = directory / record["log"]["path"]
            duplicate = (
                json.dumps(record["sample"], separators=(",", ":"), sort_keys=True)
                + "\n"
            ).encode()
            log_path.write_bytes(log_path.read_bytes() + duplicate)
            record["log"] = analyzer.file_evidence(log_path)
            write_jsonl(directory / "attempts.jsonl", fixture.records)
            write_jsonl(directory / "formal_720p.jsonl", fixture.records[4:24])
            fixture.write_manifest()
            with self.assertRaisesRegex(analyzer.EvidenceError, "found 2"):
                analyzer.analyze(directory, resamples=100)

    def test_manifest_rejects_tampered_and_missing_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            EvidenceFixture(directory).write()
            (directory / "logs" / "attempt-001.log").write_bytes(b"tampered\n")
            with self.assertRaisesRegex(analyzer.EvidenceError, "SHA mismatch"):
                analyzer.validate_manifest(directory)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            EvidenceFixture(directory).write()
            (directory / "logs" / "attempt-044.log").unlink()
            with self.assertRaisesRegex(analyzer.EvidenceError, "actual evidence files differ"):
                analyzer.validate_manifest(directory)

    def test_manifest_rejects_extra_files_even_if_manifested(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = EvidenceFixture(directory)
            fixture.write()
            (directory / "unexpected.txt").write_text("extra\n", encoding="utf-8")
            fixture.write_manifest()
            with self.assertRaisesRegex(analyzer.EvidenceError, "expected evidence paths differ"):
                analyzer.validate_manifest(directory)

    def test_default_analysis_rejects_stats_that_do_not_match_recomputation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = EvidenceFixture(directory)
            fixture.write()
            stats = json.loads((directory / "stats.json").read_text(encoding="utf-8"))
            stats["attempt_audit"]["attempts"] = 43
            write_json(directory / "stats.json", stats)
            fixture.write_manifest()
            with self.assertRaisesRegex(
                analyzer.EvidenceError, "recomputed statistics differ"
            ):
                analyzer.analyze(directory, resamples=TEST_RESAMPLES)

    def test_bootstrap_is_deterministic(self) -> None:
        ratios = [0.90, 0.91, 0.92, 0.93, 0.94, 0.95, 0.96, 0.97, 0.98, 0.99]
        first = analyzer.bootstrap_median_ci(ratios, seed=1234, resamples=1_000)
        second = analyzer.bootstrap_median_ci(ratios, seed=1234, resamples=1_000)
        self.assertEqual(first, second)
        self.assertLess(first["high"], 1)

    def test_runner_extracts_exactly_one_schema_2_saturation_record(self) -> None:
        sample = make_sample("720p", 100, ingest_cpu_per_command=100, resident_bytes=100_000_000)
        output = b"Swift Testing output\n" + json.dumps(sample).encode() + b"\n"
        self.assertEqual(runner.extract_sample(output), sample)
        with self.assertRaisesRegex(runner.RunError, "found 2"):
            runner.extract_sample(output + json.dumps(sample).encode() + b"\n")

    def test_run_logged_terminates_process_group_and_reaps_on_keyboard_interrupt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log_path = Path(temporary) / "interrupt.log"
            process = mock.Mock()
            process.pid = 4321
            process.communicate.side_effect = [
                KeyboardInterrupt(),
                (b"retained partial output\n", None),
            ]
            with mock.patch.object(runner.subprocess, "Popen", return_value=process), mock.patch.object(
                runner.os, "killpg"
            ) as killpg:
                with self.assertRaises(KeyboardInterrupt):
                    runner.run_logged(
                        ["synthetic-command"],
                        cwd=Path(temporary),
                        environment={},
                        log_path=log_path,
                        timeout_seconds=1,
                    )
            killpg.assert_called_once_with(4321, runner.signal.SIGTERM)
            self.assertEqual(log_path.read_bytes(), b"retained partial output\n")
            self.assertEqual(process.communicate.call_count, 2)


if __name__ == "__main__":
    unittest.main()
