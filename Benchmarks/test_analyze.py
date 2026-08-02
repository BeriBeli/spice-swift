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
        run: int = 1,
        boot_epoch: str = "boot-a",
        video_codec: str = "mjpeg",
        exit_code: int = 0,
        active_span_ms: float = 29_000,
        active_time_buckets: int = 10,
        last_frame_age_ms: float = 20,
        renderer: str = "cpu",
        revisioned_backing_enabled: bool = False,
        metal_2d_renderer_enabled: bool = False,
        metal_2d_command_buffers: int = 0,
        metal_2d_commands: int = 0,
        revisioned_allocated_frames: int = 0,
        cpu_fill_operations: int = 1,
    ) -> None:
        prefix = directory / f"run-{run:02d}-{client}"
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
            "renderer": renderer,
            "revisioned_backing_enabled": revisioned_backing_enabled,
            "metal_2d_renderer_enabled": metal_2d_renderer_enabled,
            "metal_2d_command_buffers": metal_2d_command_buffers,
            "metal_2d_commands": metal_2d_commands,
            "revisioned_allocated_frames": revisioned_allocated_frames,
            "pool_exhaustions": 0,
            "cpu_materializations": 0,
            "gpu_errors": 0,
            "cpu_fill_operations": cpu_fill_operations,
            "cpu_copy_bits_operations": 0,
            "cpu_bitmap_copy_operations": 0,
            "cpu_surface_copy_operations": 0,
            "cpu_scaled_copy_operations": 0,
        }
        prefix.with_suffix(".json").write_text(json.dumps(report))
        prefix.with_suffix(".meta.json").write_text(
            json.dumps(
                {
                    "boot_epoch": boot_epoch,
                    "client": client,
                    "exit_code": exit_code,
                    "observe_seconds": 30,
                    "renderer": renderer,
                    "video_codec": video_codec,
                    "run": run,
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

    def test_accepts_cpu_iosurface_without_metal_2d(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "swiftspice",
                renderer="cpu-iosurface",
                revisioned_backing_enabled=True,
                revisioned_allocated_frames=1,
            )
            report = analyze_module.load_client(directory, 1, "swiftspice")
            self.assertEqual(report["renderer"], "cpu-iosurface")

    def test_rejects_cpu_iosurface_without_revisioned_backing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(directory, "swiftspice", renderer="cpu-iosurface")
            with self.assertRaisesRegex(ValueError, "invalid cpu-iosurface"):
                analyze_module.load_client(directory, 1, "swiftspice")

    def test_rejects_automatic_metal_2d_activation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "swiftspice",
                renderer="automatic",
                revisioned_backing_enabled=True,
                metal_2d_renderer_enabled=True,
            )
            with self.assertRaisesRegex(ValueError, "invalid automatic"):
                analyze_module.load_client(directory, 1, "swiftspice")

    def test_rejects_integer_in_place_of_renderer_boolean(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "swiftspice",
                renderer="automatic",
                revisioned_backing_enabled=True,
                metal_2d_renderer_enabled=0,
            )
            with self.assertRaisesRegex(ValueError, "invalid automatic"):
                analyze_module.load_client(directory, 1, "swiftspice")

    def test_accepts_explicit_metal_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "swiftspice",
                renderer="metal",
                revisioned_backing_enabled=True,
                metal_2d_renderer_enabled=True,
                metal_2d_command_buffers=1,
                metal_2d_commands=4,
            )
            report = analyze_module.load_client(directory, 1, "swiftspice")
            self.assertEqual(report["renderer"], "metal")

    def test_rejects_renderer_metadata_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(directory, "swiftspice")
            metadata_path = directory / "run-01-swiftspice.meta.json"
            metadata = json.loads(metadata_path.read_text())
            metadata["renderer"] = "metal"
            metadata_path.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, "renderer metadata mismatch"):
                analyze_module.load_client(directory, 1, "swiftspice")

    def test_rejects_cpu_iosurface_with_metal_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "swiftspice",
                renderer="cpu-iosurface",
                revisioned_backing_enabled=True,
                revisioned_allocated_frames=1,
                metal_2d_commands=1,
            )
            with self.assertRaisesRegex(ValueError, "invalid cpu-iosurface"):
                analyze_module.load_client(directory, 1, "swiftspice")

    def test_rejects_mixed_renderers_across_pairs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for client in ("swiftspice", "spice-client-glib2"):
                self.write_sample(directory, client, run=1)
                self.write_sample(
                    directory,
                    client,
                    run=2,
                    renderer="metal",
                    revisioned_backing_enabled=True,
                    metal_2d_renderer_enabled=True,
                    metal_2d_command_buffers=1,
                    metal_2d_commands=1,
                )
            with self.assertRaisesRegex(ValueError, "mixed renderers"):
                analyze_module.analyze(directory, expected_pairs=2)

    def test_rejects_recorded_integrity_failures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for client in ("swiftspice", "spice-client-glib2"):
                self.write_sample(directory, client)
            (directory / "integrity-failures.tsv").write_text(
                "01\tswiftspice\tnative_video_evidence\n"
            )
            with self.assertRaisesRegex(ValueError, "recorded integrity failures"):
                analyze_module.analyze(directory, expected_pairs=1)

    def test_rejects_missing_metric_from_one_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for run in (1, 2):
                for client in ("swiftspice", "spice-client-glib2"):
                    self.write_sample(directory, client, run=run)
            report_path = directory / "run-02-swiftspice.json"
            report = json.loads(report_path.read_text())
            del report["fps"]
            report_path.write_text(json.dumps(report))
            with self.assertRaisesRegex(
                ValueError, "required metric fps is missing or unusable in pairs: 2"
            ):
                analyze_module.analyze(directory, expected_pairs=2)

    def test_rejects_invalid_native_video_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(directory, "swiftspice", video_codec="h264")
            with self.assertRaisesRegex(ValueError, "invalid h264 native-video"):
                analyze_module.load_client(directory, 1, "swiftspice")

    def test_accepts_complete_native_video_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(directory, "swiftspice", video_codec="h265")
            report_path = directory / "run-01-swiftspice.json"
            report = json.loads(report_path.read_text())
            report.update(
                {
                    "native_video_frames": 1,
                    "vt_decoded_frames": 1,
                    "vt_cpu_materializations": 0,
                    "advanced_cpu_fallback_frames": 0,
                    "metal_generation_disables": 0,
                }
            )
            report_path.write_text(json.dumps(report))
            loaded = analyze_module.load_client(directory, 1, "swiftspice")
            self.assertEqual(loaded["requested_video_codec"], "h265")


if __name__ == "__main__":
    unittest.main()
