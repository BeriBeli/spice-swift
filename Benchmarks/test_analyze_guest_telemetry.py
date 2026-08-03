from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "swiftspice_guest_telemetry_analyze",
    Path(__file__).with_name("analyze_guest_telemetry.py"),
)
assert SPEC is not None and SPEC.loader is not None
analyze_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyze_module)


class GuestTelemetryEvidenceTests(unittest.TestCase):
    def sample_order(self, pair: int, renderer: str) -> int:
        order = (
            analyze_module.RENDERERS
            if pair % 2 == 1
            else tuple(reversed(analyze_module.RENDERERS))
        )
        return order.index(renderer) + 1

    def global_sample_index(self, pair: int, renderer: str) -> int:
        return (pair - 1) * 2 + self.sample_order(pair, renderer)

    def write_metadata(
        self,
        result_directory: Path,
        renderer: str,
        *,
        pair: int = 1,
        observe_seconds: int = 10,
        boot_epoch: str = "boot-a",
        overrides: dict[str, object] | None = None,
    ) -> None:
        metadata: dict[str, object] = {
            "boot_epoch": boot_epoch,
            "boot_epoch_end": boot_epoch,
            "client": "swiftspice",
            "observe_seconds": observe_seconds,
            "pair": pair,
            "requested_renderer": renderer,
            "sample_order": self.sample_order(pair, renderer),
        }
        if overrides:
            metadata.update(overrides)
        path = result_directory / f"pair-{pair:02d}-{renderer}.meta.json"
        path.write_text(json.dumps(metadata))

    def telemetry_line(
        self,
        event: str,
        generation: int,
        frame_id: int,
        uptime: float,
        pid: int,
        boot_epoch: str,
    ) -> str:
        return (
            f"PERF_GENERATOR event={event} generation={generation} "
            f"frame_id={frame_id} monotonic_uptime_seconds={uptime:.2f} "
            f"pid={pid} boot_epoch={boot_epoch}\n"
        )

    def write_telemetry(
        self,
        telemetry_directory: Path,
        renderer: str,
        *,
        pair: int = 1,
        boot_epoch: str = "boot-a",
        generation: int | None = None,
        pid: int = 417,
        span: float = 9.0,
        start_uptime: float | None = None,
        prefix: str = "20260803T120000Z",
        label_prefix: str = "run",
        before_marker: str = "",
        after_marker: str | None = None,
    ) -> Path:
        sample_index = self.global_sample_index(pair, renderer)
        if generation is None:
            generation = 8 + sample_index
        if start_uptime is None:
            start_uptime = 10 + (sample_index - 1) * 20
        path = (
            telemetry_directory
            / f"{prefix}-{label_prefix}-{pair:02d}-{renderer}-guest-telemetry.log"
        )
        if after_marker is None:
            after_marker = self.telemetry_line(
                "reset", generation, 0, start_uptime, pid, boot_epoch
            )
            for heartbeat in range(1, 4):
                after_marker += self.telemetry_line(
                    "heartbeat",
                    generation,
                    heartbeat * 30,
                    start_uptime + span * heartbeat / 3,
                    pid,
                    boot_epoch,
                )
        path.write_text(before_marker + after_marker)
        return path

    def write_sample(
        self,
        result_directory: Path,
        telemetry_directory: Path,
        renderer: str,
        *,
        pair: int = 1,
        observe_seconds: int = 10,
        boot_epoch: str = "boot-a",
    ) -> None:
        self.write_metadata(
            result_directory,
            renderer,
            pair=pair,
            observe_seconds=observe_seconds,
            boot_epoch=boot_epoch,
        )
        self.write_telemetry(
            telemetry_directory,
            renderer,
            pair=pair,
            boot_epoch=boot_epoch,
        )

    def write_pair(
        self,
        result_directory: Path,
        telemetry_directory: Path,
        *,
        pair: int = 1,
    ) -> None:
        for renderer in analyze_module.RENDERERS:
            self.write_sample(
                result_directory, telemetry_directory, renderer, pair=pair
            )

    def test_accepts_complete_samples_and_ignores_old_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry, pair=1)
            self.write_pair(results, telemetry, pair=2)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            old = self.telemetry_line("start", 3, 0, 1, 100, "old-boot")
            old += self.telemetry_line("heartbeat", 3, 30, 2, 100, "old-boot")
            path.write_text(old + path.read_text())

            report = analyze_module.analyze(results, telemetry, 2, 10)

            self.assertTrue(report["passed"])
            self.assertEqual(report["validated_samples"], 4)
            self.assertEqual(report["telemetry_records"], 16)
            self.assertEqual(report["minimum_records_per_sample"], 4)
            self.assertEqual(report["minimum_window_span_seconds"], 9.0)
            self.assertEqual(report["maximum_heartbeat_gap_seconds"], 3.0)
            self.assertEqual(report["guest_generation_start"], 9)
            self.assertEqual(report["guest_generation_end"], 12)

    def test_accepts_nested_round_directory_and_start_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            rounds = telemetry / "run" / "rounds"
            results.mkdir()
            rounds.mkdir(parents=True)
            for renderer in analyze_module.RENDERERS:
                self.write_metadata(results, renderer)
                sample_index = self.global_sample_index(1, renderer)
                generation = 8 + sample_index
                start_uptime = 10 + (sample_index - 1) * 20
                selected = self.telemetry_line(
                    "start", generation, 0, start_uptime, 500, "boot-a"
                )
                selected += self.telemetry_line(
                    "heartbeat", generation, 30, start_uptime + 4, 500, "boot-a"
                )
                selected += self.telemetry_line(
                    "heartbeat", generation, 60, start_uptime + 8.5, 500, "boot-a"
                )
                self.write_telemetry(rounds, renderer, after_marker=selected)

            report = analyze_module.analyze(results, telemetry, 1, 10)

            self.assertEqual(report["validated_samples"], 2)

    def test_accepts_direct_pair_round_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            for renderer in analyze_module.RENDERERS:
                self.write_metadata(results, renderer)
                self.write_telemetry(
                    telemetry, renderer, label_prefix="direct-pair"
                )

            report = analyze_module.analyze(results, telemetry, 1, 10)

            self.assertEqual(report["validated_samples"], 2)

    def test_rejects_incomplete_metadata_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_sample(results, telemetry, "cpu-iosurface")
            with self.assertRaisesRegex(
                ValueError, "incomplete direct renderer metadata"
            ):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_metadata_observation_duration_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            self.write_metadata(results, "metal", observe_seconds=30)
            with self.assertRaisesRegex(ValueError, "observation duration mismatch"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_metadata_sample_order_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            self.write_metadata(results, "metal", overrides={"sample_order": 1})
            with self.assertRaisesRegex(ValueError, "sample order mismatch"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_missing_telemetry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            next(telemetry.glob("*-run-01-metal-guest-telemetry.log")).unlink()
            with self.assertRaisesRegex(ValueError, "missing guest telemetry"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_duplicate_telemetry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            self.write_telemetry(
                telemetry, "metal", prefix="20260803T130000Z"
            )
            with self.assertRaisesRegex(ValueError, "duplicate guest telemetry"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_duplicate_telemetry_across_round_name_styles(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            self.write_telemetry(
                telemetry, "metal", label_prefix="direct-pair"
            )
            with self.assertRaisesRegex(ValueError, "duplicate guest telemetry"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_renamed_duplicate_telemetry_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            cpu = next(telemetry.glob("*-run-01-cpu-iosurface-guest-telemetry.log"))
            metal = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            metal.write_text(cpu.read_text())
            with self.assertRaisesRegex(
                ValueError, "guest generation did not advance once per sample"
            ):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_generation_skip_across_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            self.write_telemetry(telemetry, "metal", generation=11)
            with self.assertRaisesRegex(
                ValueError, "guest generation did not advance once per sample"
            ):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_pid_change_across_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            self.write_telemetry(telemetry, "metal", pid=999)
            with self.assertRaisesRegex(
                ValueError, "mixed guest generator PIDs across direct renderer batch"
            ):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_boot_change_across_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            self.write_metadata(results, "metal", boot_epoch="boot-b")
            self.write_telemetry(telemetry, "metal", boot_epoch="boot-b")
            with self.assertRaisesRegex(
                ValueError, "mixed guest boot epochs across direct renderer batch"
            ):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_overlapping_sample_windows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            self.write_telemetry(telemetry, "metal", start_uptime=15)
            with self.assertRaisesRegex(
                ValueError, "guest telemetry sample windows overlap or regress"
            ):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_boot_epoch_mismatch_after_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            invalid = self.telemetry_line("reset", 9, 0, 10, 417, "wrong-boot")
            invalid += self.telemetry_line(
                "heartbeat", 9, 30, 19, 417, "wrong-boot"
            )
            path.write_text(invalid)
            with self.assertRaisesRegex(ValueError, "guest boot epoch mismatch"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_mixed_generation_after_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            invalid = self.telemetry_line("reset", 9, 0, 10, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 10, 30, 19, 417, "boot-a")
            path.write_text(invalid)
            with self.assertRaisesRegex(ValueError, "mixed guest generations"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_mixed_pid_after_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            invalid = self.telemetry_line("reset", 9, 0, 10, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 9, 30, 19, 999, "boot-a")
            path.write_text(invalid)
            with self.assertRaisesRegex(ValueError, "mixed guest generator PIDs"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_non_monotonic_frame_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            invalid = self.telemetry_line("reset", 9, 0, 10, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 9, 30, 15, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 9, 30, 19, 417, "boot-a")
            path.write_text(invalid)
            with self.assertRaisesRegex(ValueError, "non-monotonic guest frame_id"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_non_monotonic_uptime(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            invalid = self.telemetry_line("reset", 9, 0, 10, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 9, 30, 19, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 9, 60, 18, 417, "boot-a")
            path.write_text(invalid)
            with self.assertRaisesRegex(ValueError, "non-monotonic guest uptime"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_insufficient_window_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            invalid = self.telemetry_line("reset", 9, 0, 10, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 9, 30, 12.5, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 9, 60, 15, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 9, 90, 17.9, 417, "boot-a")
            path.write_text(invalid)
            with self.assertRaisesRegex(
                ValueError, "incomplete guest telemetry window"
            ):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_excessive_heartbeat_gap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            invalid = self.telemetry_line("reset", 10, 0, 30, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 10, 30, 32, 417, "boot-a")
            invalid += self.telemetry_line("heartbeat", 10, 60, 38, 417, "boot-a")
            path.write_text(invalid)
            with self.assertRaisesRegex(ValueError, "guest telemetry heartbeat gap"):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_rejects_marker_without_heartbeat(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            path = next(telemetry.glob("*-run-01-metal-guest-telemetry.log"))
            path.write_text(self.telemetry_line("reset", 9, 0, 10, 417, "boot-a"))
            with self.assertRaisesRegex(
                ValueError, "incomplete guest telemetry samples"
            ):
                analyze_module.analyze(results, telemetry, 1, 10)

    def test_cli_outputs_compact_json_and_failure_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = root / "results"
            telemetry = root / "telemetry"
            results.mkdir()
            telemetry.mkdir()
            self.write_pair(results, telemetry)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = analyze_module.main(
                    [
                        str(results),
                        str(telemetry),
                        "--expected-pairs",
                        "1",
                        "--observe-seconds",
                        "10",
                    ]
                )
            self.assertEqual(result, 0)
            self.assertTrue(json.loads(stdout.getvalue())["passed"])
            self.assertEqual(len(stdout.getvalue().splitlines()), 1)

            next(telemetry.glob("*-run-01-metal-guest-telemetry.log")).unlink()
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = analyze_module.main(
                    [
                        str(results),
                        str(telemetry),
                        "--expected-pairs",
                        "1",
                        "--observe-seconds",
                        "10",
                    ]
                )
            self.assertEqual(result, 1)
            failure = json.loads(stderr.getvalue())
            self.assertFalse(failure["passed"])
            self.assertIn("missing guest telemetry", failure["error"])


if __name__ == "__main__":
    unittest.main()
