from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "swiftspice_benchmark_analyze", Path(__file__).with_name("analyze.py")
)
assert SPEC is not None and SPEC.loader is not None
analyze_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyze_module)


class BenchmarkEvidenceTests(unittest.TestCase):
    def write_sample(
        self,
        directory: Path,
        client: str,
        *,
        boot_epoch: str = "boot-a",
        exit_code: int = 0,
        active_span_ms: float = 29_000,
        active_time_buckets: int = 10,
        last_frame_age_ms: float = 20,
    ) -> None:
        prefix = directory / f"run-01-{client}"
        report = {
            "client": client,
            "observe_seconds": 30,
            "frames": 1_500,
            "fps": 50,
            "ready_frame_ms": 200,
            "p95_interframe_ms": 20,
            "observe_cpu_seconds": 1,
            "active_span_ms": active_span_ms,
            "last_frame_age_ms": last_frame_age_ms,
            "active_time_buckets": active_time_buckets,
            "expected_time_buckets": 10,
        }
        prefix.with_suffix(".json").write_text(json.dumps(report))
        prefix.with_suffix(".meta.json").write_text(
            json.dumps(
                {
                    "boot_epoch": boot_epoch,
                    "client": client,
                    "exit_code": exit_code,
                    "observe_seconds": 30,
                    "run": 1,
                }
            )
        )
        prefix.with_suffix(".time.txt").write_text(
            "real 30.0\nuser 1.0\nsys 0.0\n1000000 maximum resident set size\n"
        )

    def test_accepts_full_activity_window(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(directory, "swiftspice")
            report = analyze_module.load_client(directory, 1, "swiftspice")
            self.assertEqual(report["boot_epoch"], "boot-a")

    def test_rejects_partial_activity_window(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "spice-client-glib2",
                active_span_ms=8_000,
                active_time_buckets=3,
                last_frame_age_ms=20_000,
            )
            with self.assertRaisesRegex(ValueError, "incomplete benchmark activity"):
                analyze_module.load_client(directory, 1, "spice-client-glib2")

    def test_rejects_nonzero_exit_after_valid_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(directory, "swiftspice", exit_code=134)
            with self.assertRaisesRegex(ValueError, "exited unsuccessfully"):
                analyze_module.load_client(directory, 1, "swiftspice")

    def test_rejects_cross_epoch_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(directory, "swiftspice", boot_epoch="boot-a")
            self.write_sample(directory, "spice-client-glib2", boot_epoch="boot-b")
            with self.assertRaisesRegex(ValueError, "boot epoch changed within pair"):
                analyze_module.analyze(directory, expected_pairs=1)


if __name__ == "__main__":
    unittest.main()
