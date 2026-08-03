from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "swiftspice_renderer_pair_analyze",
    Path(__file__).with_name("analyze_renderer_pairs.py"),
)
assert SPEC is not None and SPEC.loader is not None
analyze_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyze_module)


class RendererPairEvidenceTests(unittest.TestCase):
    def write_sample(
        self,
        directory: Path,
        renderer: str,
        *,
        pair: int = 1,
        sample_order: int | None = None,
        boot_epoch: str = "boot-a",
        video_codec: str = "mjpeg",
        resolution: str = "1280x720",
        reset_source: str = "reset-script",
        frames: int = 1_500,
        frame_bytes: int | None = None,
        fps: float = 50,
        ready_frame_ms: float = 200,
        p95_interframe_ms: float = 20,
        observe_cpu_seconds: float = 1.5,
        maximum_rss_bytes: int = 1_000_000,
        report_overrides: dict[str, object] | None = None,
        metadata_overrides: dict[str, object] | None = None,
    ) -> None:
        if sample_order is None:
            if pair % 2 == 1:
                sample_order = 1 if renderer == "cpu-iosurface" else 2
            else:
                sample_order = 1 if renderer == "metal" else 2
        try:
            width_text, height_text = resolution.split("x", maxsplit=1)
            bytes_per_frame = int(width_text) * int(height_text) * 4
        except (ValueError, TypeError):
            bytes_per_frame = 1280 * 720 * 4
        if frame_bytes is None:
            frame_bytes = frames * bytes_per_frame

        is_metal = renderer == "metal"
        report: dict[str, object] = {
            "client": "swiftspice",
            "renderer": renderer,
            "observe_seconds": 30,
            "frames": frames,
            "frame_bytes": frame_bytes,
            "fps": fps,
            "ready_frame_ms": ready_frame_ms,
            "p95_interframe_ms": p95_interframe_ms,
            "observe_cpu_seconds": observe_cpu_seconds,
            "active_span_ms": 29_000,
            "last_frame_age_ms": 20,
            "active_time_buckets": 10,
            "expected_time_buckets": 10,
            "revisioned_backing_enabled": True,
            "metal_2d_renderer_enabled": is_metal,
            "metal_2d_command_buffers": 1 if is_metal else 0,
            "metal_2d_commands": 4 if is_metal else 0,
            "metal_2d_cpu_fallback_operations": 0,
            "revisioned_allocated_frames": 1,
            "pool_exhaustions": 0,
            "cpu_materializations": 0,
            "gpu_errors": 0,
            "cpu_fill_operations": 0 if is_metal else 1,
            "cpu_copy_bits_operations": 0,
            "cpu_bitmap_copy_operations": 0,
            "cpu_surface_copy_operations": 0,
            "cpu_scaled_copy_operations": 0,
        }
        if video_codec != "mjpeg":
            report.update(
                {
                    "native_video_frames": 1,
                    "vt_decoded_frames": 1,
                    "vt_cpu_materializations": 0,
                    "advanced_cpu_fallback_frames": 0,
                    "metal_generation_disables": 0,
                }
            )
        if report_overrides:
            report.update(report_overrides)

        metadata: dict[str, object] = {
            "boot_epoch": boot_epoch,
            "boot_epoch_end": boot_epoch,
            "boot_epoch_end_exit_code": 0,
            "client": "swiftspice",
            "deterministic_reset_source": reset_source,
            "exit_code": 0,
            "hook_after_exit_code": 0,
            "observe_seconds": 30,
            "pair": pair,
            "requested_renderer": renderer,
            "resolution": resolution,
            "sample_order": sample_order,
            "video_codec": video_codec,
        }
        if metadata_overrides:
            metadata.update(metadata_overrides)

        prefix = directory / f"pair-{pair:02d}-{renderer}"
        prefix.with_suffix(".json").write_text(json.dumps(report))
        prefix.with_suffix(".meta.json").write_text(json.dumps(metadata))
        prefix.with_suffix(".time.txt").write_text(
            "real 30.0\nuser 1.0\nsys 0.0\n"
            f"{maximum_rss_bytes} maximum resident set size\n"
        )

    def write_pair(
        self, directory: Path, *, pair: int = 1, **sample_arguments: object
    ) -> None:
        for renderer in ("cpu-iosurface", "metal"):
            self.write_sample(
                directory, renderer, pair=pair, **sample_arguments
            )

    def test_reports_metal_over_cpu_iosurface_ratios(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "cpu-iosurface",
                fps=50,
                ready_frame_ms=200,
                p95_interframe_ms=20,
                observe_cpu_seconds=3,
                maximum_rss_bytes=1_000_000,
            )
            self.write_sample(
                directory,
                "metal",
                fps=52,
                ready_frame_ms=190,
                p95_interframe_ms=19,
                observe_cpu_seconds=2.7,
                maximum_rss_bytes=1_100_000,
            )
            report = analyze_module.analyze(directory, expected_pairs=1)
            self.assertEqual(report["comparison"], "metal/cpu-iosurface")
            self.assertEqual(report["resolution"], "1280x720")
            self.assertEqual(report["boot_epoch"], "boot-a")
            self.assertAlmostEqual(report["metrics"]["fps"]["median_ratio"], 1.04)
            self.assertAlmostEqual(
                report["metrics"]["observe_cpu_seconds_per_frame"][
                    "median_ratio"
                ],
                0.9,
            )
            self.assertTrue(report["passed"])

    def test_uses_pairwise_ratio_median(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            baseline_fps = (1, 10, 100)
            metal_fps = (1, 100, 20)
            for pair, (baseline, metal) in enumerate(
                zip(baseline_fps, metal_fps, strict=True), start=1
            ):
                self.write_sample(
                    directory, "cpu-iosurface", pair=pair, fps=baseline
                )
                self.write_sample(directory, "metal", pair=pair, fps=metal)
            report = analyze_module.analyze(directory, expected_pairs=3)
            self.assertEqual(report["metrics"]["fps"]["median_ratio"], 1.0)

    def test_accepts_required_alternating_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory, pair=1)
            self.write_pair(directory, pair=2)
            report = analyze_module.analyze(directory, expected_pairs=2)
            self.assertEqual(report["paired_runs"], 2)

    def test_accepts_hook_as_deterministic_reset_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory, reset_source="hook")
            report = analyze_module.analyze(directory, expected_pairs=1)
            self.assertEqual(report["deterministic_reset_source"], "hook")

    def test_rejects_non_alternating_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory, pair=1)
            self.write_sample(
                directory, "cpu-iosurface", pair=2, sample_order=1
            )
            self.write_sample(directory, "metal", pair=2, sample_order=2)
            with self.assertRaisesRegex(ValueError, "alternating renderer order"):
                analyze_module.analyze(directory, expected_pairs=2)

    def test_rejects_duplicate_sample_ordinals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory, "cpu-iosurface", pair=1, sample_order=1
            )
            self.write_sample(directory, "metal", pair=1, sample_order=1)
            with self.assertRaisesRegex(ValueError, "invalid sample ordinals"):
                analyze_module.analyze(directory, expected_pairs=1)

    def test_rejects_boot_epoch_change_between_pairs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory, pair=1, boot_epoch="boot-a")
            self.write_pair(directory, pair=2, boot_epoch="boot-b")
            with self.assertRaisesRegex(ValueError, "mixed boot epochs"):
                analyze_module.analyze(directory, expected_pairs=2)

    def test_rejects_boot_epoch_change_during_sample(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "metal",
                metadata_overrides={"boot_epoch_end": "boot-b"},
            )
            with self.assertRaisesRegex(ValueError, "changed during sample"):
                analyze_module.load_renderer(directory, 1, "metal")

    def test_rejects_mixed_codec_across_batch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory, pair=1)
            self.write_pair(directory, pair=2, video_codec="h264")
            with self.assertRaisesRegex(ValueError, "mixed video codecs"):
                analyze_module.analyze(directory, expected_pairs=2)

    def test_rejects_mixed_resolution_across_batch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory, pair=1)
            self.write_pair(directory, pair=2, resolution="1920x1080")
            with self.assertRaisesRegex(ValueError, "mixed resolutions"):
                analyze_module.analyze(directory, expected_pairs=2)

    def test_rejects_resolution_footprint_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "cpu-iosurface",
                frame_bytes=1_500 * 1280 * 720 * 4 - 1,
            )
            with self.assertRaisesRegex(ValueError, "not frame-aligned"):
                analyze_module.load_renderer(directory, 1, "cpu-iosurface")

    def test_rejects_wrong_frame_aligned_resolution_footprint(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "cpu-iosurface",
                frame_bytes=1_500 * 1920 * 1080 * 4,
            )
            with self.assertRaisesRegex(ValueError, "resolution evidence mismatch"):
                analyze_module.load_renderer(directory, 1, "cpu-iosurface")

    def test_rejects_resolution_evidence_overflow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "cpu-iosurface",
                resolution="9999999999x9999999999",
                frame_bytes=1,
            )
            with self.assertRaisesRegex(ValueError, "resolution evidence overflow"):
                analyze_module.load_renderer(directory, 1, "cpu-iosurface")

    def test_rejects_incomplete_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(directory, "cpu-iosurface")
            with self.assertRaisesRegex(ValueError, "incomplete direct renderer pairs"):
                analyze_module.analyze(directory, expected_pairs=1)

    def test_rejects_non_contiguous_pair_numbers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory, pair=1)
            self.write_pair(directory, pair=3)
            with self.assertRaisesRegex(ValueError, "non-contiguous"):
                analyze_module.analyze(directory)

    def test_rejects_wrong_requested_renderer_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "cpu-iosurface",
                metadata_overrides={"requested_renderer": "metal"},
            )
            with self.assertRaisesRegex(ValueError, "sample identity mismatch"):
                analyze_module.load_renderer(directory, 1, "cpu-iosurface")

    def test_rejects_cpu_iosurface_metal_activity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "cpu-iosurface",
                report_overrides={"metal_2d_commands": 1},
            )
            with self.assertRaisesRegex(ValueError, "invalid cpu-iosurface"):
                analyze_module.load_renderer(directory, 1, "cpu-iosurface")

    def test_rejects_metal_cpu_fallback_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "metal",
                report_overrides={"metal_2d_cpu_fallback_operations": 1},
            )
            with self.assertRaisesRegex(
                ValueError, "invalid metal.*metal_2d_cpu_fallback_operations"
            ):
                analyze_module.load_renderer(directory, 1, "metal")

    def test_rejects_metal_scaled_copy_in_direct_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "metal",
                report_overrides={"cpu_scaled_copy_operations": 1},
            )
            with self.assertRaisesRegex(
                ValueError, "invalid direct metal.*cpu_scaled_copy_operations"
            ):
                analyze_module.load_renderer(directory, 1, "metal")

    def test_rejects_cpu_iosurface_materialization_for_native_video(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "cpu-iosurface",
                video_codec="h264",
                report_overrides={"cpu_materializations": 1},
            )
            with self.assertRaisesRegex(
                ValueError, "invalid direct cpu-iosurface.*cpu_materializations"
            ):
                analyze_module.load_renderer(directory, 1, "cpu-iosurface")

    def test_rejects_incomplete_activity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "metal",
                report_overrides={
                    "active_span_ms": 8_000,
                    "active_time_buckets": 3,
                    "last_frame_age_ms": 20_000,
                },
            )
            with self.assertRaisesRegex(ValueError, "incomplete benchmark activity"):
                analyze_module.load_renderer(directory, 1, "metal")

    def test_rejects_missing_deterministic_reset_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "metal",
                metadata_overrides={"deterministic_reset_source": "none"},
            )
            with self.assertRaisesRegex(ValueError, "deterministic reset evidence"):
                analyze_module.load_renderer(directory, 1, "metal")

    def test_rejects_failed_after_hook(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_sample(
                directory,
                "metal",
                metadata_overrides={"hook_after_exit_code": 1},
            )
            with self.assertRaisesRegex(ValueError, "after hook exited unsuccessfully"):
                analyze_module.load_renderer(directory, 1, "metal")

    def test_rejects_recorded_integrity_failures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory)
            (directory / "integrity-failures.tsv").write_text(
                "01\tmetal\trenderer_evidence\n"
            )
            with self.assertRaisesRegex(ValueError, "recorded integrity failures"):
                analyze_module.analyze(directory, expected_pairs=1)

    def test_rejects_missing_required_metric(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_pair(directory)
            path = directory / "pair-01-metal.json"
            report = json.loads(path.read_text())
            del report["fps"]
            path.write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "required metric fps"):
                analyze_module.analyze(directory, expected_pairs=1)


if __name__ == "__main__":
    unittest.main()
