#!/usr/bin/env python3
"""Run the formal host-only commit-to-commit CPU saturation A/B protocol.

The result is locked to the exact runner and analyzer bytes. Preserve and use
the originating repository commit when revalidating historical evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import signal
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


RUNNER_SOURCE_PATH = Path(__file__).resolve()
ANALYZER_SOURCE_PATH = RUNNER_SOURCE_PATH.with_name("analyze_cpu_saturation.py")
FROZEN_RUNNER_BYTES = RUNNER_SOURCE_PATH.read_bytes()
FROZEN_ANALYZER_BYTES = ANALYZER_SOURCE_PATH.read_bytes()

import analyze_cpu_saturation as analyzer


HARNESS_PATH = Path("Tests/SpiceCoreTests/CPUHotPathBenchmarkTests.swift")
RUNNER_REPOSITORY_PATH = Path("Benchmarks/run_cpu_saturation_ab.py")
ANALYZER_REPOSITORY_PATH = Path("Benchmarks/analyze_cpu_saturation.py")
RUNNER_EVIDENCE_PATH = Path("tools/run_cpu_saturation_ab.py")
ANALYZER_EVIDENCE_PATH = Path("tools/analyze_cpu_saturation.py")
WARMUP_PLAN = (
    ("720p", "baseline"),
    ("720p", "optimized"),
    ("4k", "optimized"),
    ("4k", "baseline"),
)


class RunError(RuntimeError):
    """Raised after evidence for a failed, non-replaceable attempt is retained."""


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def command_output(command: Sequence[str], *, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return completed.stdout.strip()


def git_output(repo: Path, *arguments: str) -> str:
    return command_output(("git", "-C", str(repo), *arguments))


def resolve_commit(repo: Path, revision: str) -> str:
    commit = git_output(repo, "rev-parse", "--verify", f"{revision}^{{commit}}")
    if analyzer.COMMIT_PATTERN.fullmatch(commit) is None:
        raise RunError(f"git returned an unsupported commit identifier: {commit!r}")
    return commit


def git_blob(repo: Path, commit: str, path: Path) -> bytes:
    completed = subprocess.run(
        ("git", "-C", str(repo), "show", f"{commit}:{path.as_posix()}"),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout


def verify_frozen_tools_match_commit(repo: Path, tool_commit: str) -> None:
    expected = {
        RUNNER_REPOSITORY_PATH: FROZEN_RUNNER_BYTES,
        ANALYZER_REPOSITORY_PATH: FROZEN_ANALYZER_BYTES,
    }
    for repository_path, frozen_bytes in expected.items():
        committed_bytes = git_blob(repo, tool_commit, repository_path)
        if committed_bytes != frozen_bytes:
            raise RunError(
                f"startup-frozen {repository_path} differs from tool commit {tool_commit}"
            )


def verify_frozen_tools_unchanged() -> None:
    current = {
        RUNNER_SOURCE_PATH: FROZEN_RUNNER_BYTES,
        ANALYZER_SOURCE_PATH: FROZEN_ANALYZER_BYTES,
    }
    for source_path, frozen_bytes in current.items():
        if source_path.read_bytes() != frozen_bytes:
            raise RunError(f"tool changed while the formal run was active: {source_path}")


def write_frozen_tools(output_directory: Path) -> None:
    frozen = {
        RUNNER_EVIDENCE_PATH: FROZEN_RUNNER_BYTES,
        ANALYZER_EVIDENCE_PATH: FROZEN_ANALYZER_BYTES,
    }
    for relative_path, data in frozen.items():
        path = output_directory / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755)


def clean_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for key in tuple(environment):
        if key.startswith("SWIFTSPICE_CPU_HOTPATH_"):
            environment.pop(key)
    return environment


def retained_file(path: Path, output_directory: Path) -> dict[str, Any]:
    data = path.read_bytes()
    return {
        "path": path.relative_to(output_directory).as_posix(),
        "sha256": sha256_bytes(data),
        "bytes": len(data),
    }


def write_json(path: Path, value: Any) -> None:
    rendered = json.dumps(value, indent=2, separators=(",", ": "), sort_keys=True) + "\n"
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(rendered, encoding="utf-8")
    temporary.replace(path)


def append_jsonl(path: Path, value: Any) -> None:
    rendered = json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n"
    with path.open("a", encoding="utf-8") as stream:
        stream.write(rendered)
        stream.flush()
        os.fsync(stream.fileno())


def terminate_process_group(process: subprocess.Popen[bytes]) -> bytes:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        output, _ = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = process.communicate()
    return output


def run_logged(
    command: Sequence[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    log_path: Path,
    timeout_seconds: int,
) -> tuple[int, str | None, int]:
    failure: str | None = None
    process = subprocess.Popen(
        list(command),
        cwd=cwd,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
        exit_code = process.returncode
    except subprocess.TimeoutExpired:
        exit_code = 124
        failure = f"process exceeded {timeout_seconds} second timeout"
        try:
            output = terminate_process_group(process)
        except BaseException:
            output = b""
            log_path.write_bytes(output)
            raise
    except BaseException:
        try:
            output = terminate_process_group(process)
        except BaseException:
            output = b""
        log_path.write_bytes(output)
        raise
    log_path.write_bytes(output)
    return exit_code, failure, process.pid


def extract_sample(output: bytes) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    for raw_line in output.decode("utf-8", errors="replace").splitlines():
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
    if len(candidates) != 1:
        raise RunError(f"expected one schema-2 cpu-iosurface saturation record, found {len(candidates)}")
    return candidates[0]


def host_metadata() -> dict[str, Any]:
    boot_time = command_output(("sysctl", "-n", "kern.boottime"))
    match = re.search(r"\bsec\s*=\s*(\d+)", boot_time)
    if match is None:
        raise RunError(f"could not parse kern.boottime: {boot_time!r}")
    boot_epoch_seconds = int(match.group(1))
    return {
        "system": platform.system(),
        "machine": platform.machine(),
        "hardware_model": command_output(("sysctl", "-n", "hw.model")),
        "cpu_brand": command_output(("sysctl", "-n", "machdep.cpu.brand_string")),
        "boot_epoch_seconds": boot_epoch_seconds,
        "boot_time_utc": datetime.fromtimestamp(
            boot_epoch_seconds, timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "collected_at_utc": utc_now(),
        "os_version": command_output(("sw_vers", "-productVersion")),
        "os_build": command_output(("sw_vers", "-buildVersion")),
        "swift": command_output(("swift", "--version")),
        "xcode": command_output(("xcodebuild", "-version")),
    }


def sample_command(scratch_path: Path) -> list[str]:
    return [
        "swift",
        "test",
        "-c",
        "release",
        "--scratch-path",
        str(scratch_path),
        "--skip-build",
        "--disable-sandbox",
        "--filter",
        "CPUHotPathBenchmarkTests",
    ]


def build_command(scratch_path: Path) -> list[str]:
    return [
        "swift",
        "test",
        "-c",
        "release",
        "--scratch-path",
        str(scratch_path),
        "--disable-sandbox",
        "-Xswiftc",
        "-warnings-as-errors",
        "--filter",
        "CPUHotPathBenchmarkTests",
    ]


def benchmark_environment(
    base: dict[str, str],
    *,
    resolution: str,
    frames: int,
    module_root: Path,
) -> tuple[dict[str, str], dict[str, str]]:
    declared = {
        "SWIFTSPICE_CPU_HOTPATH_BENCHMARK": "1",
        "SWIFTSPICE_CPU_HOTPATH_BACKEND": "cpu-iosurface",
        "SWIFTSPICE_CPU_HOTPATH_INPUT_MODE": "saturation",
        "SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS": "0",
        "SWIFTSPICE_CPU_HOTPATH_RESOLUTION": resolution,
        "SWIFTSPICE_CPU_HOTPATH_FRAMES": str(frames),
    }
    environment = base.copy()
    environment.update(declared)
    environment["CLANG_MODULE_CACHE_PATH"] = str(module_root / "clang")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(module_root / "swiftpm")
    return environment, declared


def add_worktree(repo: Path, path: Path, commit: str) -> None:
    subprocess.run(
        ("git", "-C", str(repo), "worktree", "add", "--detach", str(path), commit),
        check=True,
    )
    actual = git_output(path, "rev-parse", "HEAD")
    if actual != commit:
        raise RunError(f"worktree {path} resolved to {actual}, expected {commit}")


def remove_worktree(repo: Path, path: Path) -> None:
    if path.exists():
        subprocess.run(
            ("git", "-C", str(repo), "worktree", "remove", "--force", str(path)),
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def write_checksums(directory: Path) -> None:
    paths = sorted(
        path
        for path in directory.rglob("*")
        if path.is_file() and path.name not in {"SHA256SUMS", "metadata.json.tmp"}
    )
    lines = [f"{sha256_file(path)}  {path.relative_to(directory).as_posix()}" for path in paths]
    (directory / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="exact baseline commit or resolvable revision")
    parser.add_argument("--optimized", required=True, help="exact optimized commit or resolvable revision")
    parser.add_argument(
        "--frames",
        type=int,
        default=analyzer.FORMAL_FRAMES,
        help=f"predeclared formal input frames (fixed at {analyzer.FORMAL_FRAMES})",
    )
    parser.add_argument("--output", required=True, type=Path, help="new evidence directory")
    parser.add_argument(
        "--repo",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="source repository (defaults to this script's repository)",
    )
    parser.add_argument(
        "--tool-commit",
        default="HEAD",
        help="commit containing the exact runner/analyzer blobs (default: HEAD)",
    )
    parser.add_argument("--sample-timeout-seconds", type=int, default=180)
    parser.add_argument(
        "--host-execution-confirmed",
        action="store_true",
        help="required acknowledgement that this command runs outside the Codex sandbox",
    )
    parser.add_argument("--keep-worktrees", action="store_true")
    args = parser.parse_args()

    if not args.host_execution_confirmed:
        parser.error("--host-execution-confirmed is required by AGENTS.md")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("formal CPU-IOSurface evidence requires an Apple Silicon macOS host")
    if args.frames != analyzer.FORMAL_FRAMES:
        parser.error(
            f"formal protocol fixes --frames at {analyzer.FORMAL_FRAMES}; "
            "run 2-frame smoke commands separately"
        )
    if args.sample_timeout_seconds < 1:
        parser.error("--sample-timeout-seconds must be positive")

    repo = Path(git_output(args.repo.resolve(), "rev-parse", "--show-toplevel"))
    tool_commit = resolve_commit(repo, args.tool_commit)
    verify_frozen_tools_match_commit(repo, tool_commit)
    verify_frozen_tools_unchanged()
    collected_host_metadata = host_metadata()
    output_directory = args.output.resolve()
    if output_directory.exists():
        parser.error(f"refusing to overwrite existing output: {output_directory}")
    output_directory.mkdir(parents=True)
    logs_directory = output_directory / "logs"
    logs_directory.mkdir()
    write_frozen_tools(output_directory)

    baseline_commit = resolve_commit(repo, args.baseline)
    optimized_commit = resolve_commit(repo, args.optimized)
    if baseline_commit == optimized_commit:
        parser.error("baseline and optimized resolve to the same commit")
    baseline_harness = git_blob(repo, baseline_commit, HARNESS_PATH)
    optimized_harness = git_blob(repo, optimized_commit, HARNESS_PATH)
    if baseline_harness != optimized_harness:
        parser.error("benchmark harness bytes differ between baseline and optimized commits")
    harness_sha256 = sha256_bytes(baseline_harness)

    work_root = Path(tempfile.mkdtemp(prefix="swiftspice-cpu-saturation-"))
    worktrees = {
        "baseline": work_root / "baseline",
        "optimized": work_root / "optimized",
    }
    scratches = {
        "baseline": work_root / "scratch-baseline",
        "optimized": work_root / "scratch-optimized",
    }
    module_roots = {
        "baseline": work_root / "modules-baseline",
        "optimized": work_root / "modules-optimized",
    }
    commits = {"baseline": baseline_commit, "optimized": optimized_commit}
    base_environment = clean_environment()
    builds: list[dict[str, Any]] = []
    all_records: list[dict[str, Any]] = []

    try:
        for label in ("baseline", "optimized"):
            add_worktree(repo, worktrees[label], commits[label])
            file_harness_sha = sha256_file(worktrees[label] / HARNESS_PATH)
            if file_harness_sha != harness_sha256:
                raise RunError(f"{label} checked-out harness bytes changed")

        for label in ("baseline", "optimized"):
            command = build_command(scratches[label])
            log_path = logs_directory / f"build-{label}.log"
            environment = base_environment.copy()
            environment["CLANG_MODULE_CACHE_PATH"] = str(module_roots[label] / "clang")
            environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(module_roots[label] / "swiftpm")
            exit_code, timeout_failure, _ = run_logged(
                command,
                cwd=worktrees[label],
                environment=environment,
                log_path=log_path,
                timeout_seconds=900,
            )
            builds.append(
                {
                    "label": label,
                    "commit": commits[label],
                    "exit_code": exit_code,
                    "command": command,
                    "log": retained_file(log_path, output_directory),
                }
            )
            if exit_code != 0:
                detail = timeout_failure or f"Release build exited {exit_code}"
                raise RunError(f"{label}: {detail}; see {log_path}")

        plans: list[dict[str, Any]] = []
        for resolution, label in WARMUP_PLAN:
            plans.append(
                {
                    "phase": "discarded-warmup",
                    "resolution": resolution,
                    "label": label,
                    "pair": None,
                    "order": None,
                    "sequence": None,
                }
            )
        for resolution in analyzer.RESOLUTIONS:
            for pair in range(1, analyzer.PAIR_COUNT + 1):
                order, labels = analyzer.expected_formal_order(pair)
                for sequence, label in enumerate(labels, start=1):
                    plans.append(
                        {
                            "phase": "formal",
                            "resolution": resolution,
                            "label": label,
                            "pair": pair,
                            "order": order,
                            "sequence": sequence,
                        }
                    )

        for run_index, plan in enumerate(plans, start=1):
            label = plan["label"]
            resolution = plan["resolution"]
            command = sample_command(scratches[label])
            environment, declared_environment = benchmark_environment(
                base_environment,
                resolution=resolution,
                frames=args.frames,
                module_root=module_roots[label],
            )
            log_path = logs_directory / f"attempt-{run_index:03d}.log"
            started_at = utc_now()
            exit_code, timeout_failure, process_id = run_logged(
                command,
                cwd=worktrees[label],
                environment=environment,
                log_path=log_path,
                timeout_seconds=args.sample_timeout_seconds,
            )
            finished_at = utc_now()
            sample: dict[str, Any] | None = None
            failure = timeout_failure
            if exit_code == 0 and failure is None:
                try:
                    sample = extract_sample(log_path.read_bytes())
                    analyzer.validate_sample(
                        sample,
                        resolution,
                        args.frames,
                        f"attempt {run_index} immediate gate",
                    )
                except (RunError, analyzer.EvidenceError) as error:
                    failure = str(error)
            elif failure is None:
                failure = f"benchmark process exited {exit_code}"
            status = "succeeded" if failure is None else "failed"
            record = {
                "schema_version": 2,
                "status": status,
                "run_index": run_index,
                "phase": plan["phase"],
                "resolution": resolution,
                "label": label,
                "commit": commits[label],
                "harness_sha256": harness_sha256,
                "pair": plan["pair"],
                "order": plan["order"],
                "sequence": plan["sequence"],
                "started_at_utc": started_at,
                "finished_at_utc": finished_at,
                "exit_code": exit_code,
                "sample": sample,
                "execution": {
                    "scope": "host-outside-codex-sandbox",
                    "fresh_process": True,
                    "launcher_process_id": process_id,
                    "build_configuration": "release",
                    "command": command,
                    "environment": declared_environment,
                },
                "log": retained_file(log_path, output_directory),
                "failure": failure,
            }
            all_records.append(record)
            append_jsonl(output_directory / "attempts.jsonl", record)
            phase_path = (
                output_directory / "warmups.jsonl"
                if plan["phase"] == "discarded-warmup"
                else output_directory / f"formal_{resolution}.jsonl"
            )
            append_jsonl(phase_path, record)
            if failure is not None:
                raise RunError(
                    f"attempt {run_index} failed and was retained without replacement: {failure}; "
                    f"see {log_path}"
                )

        verify_frozen_tools_unchanged()
        metadata = {
            "schema_version": 2,
            "protocol": analyzer.PROTOCOL,
            "status": "complete",
            "run_window_utc": {
                "started": all_records[0]["started_at_utc"],
                "finished": all_records[-1]["finished_at_utc"],
            },
            "host": collected_host_metadata,
            "provenance": {
                "baseline_commit": baseline_commit,
                "optimized_commit": optimized_commit,
                "harness_path": HARNESS_PATH.as_posix(),
                "common_harness_sha256": harness_sha256,
                "tool_commit": tool_commit,
                "tool_files": {
                    "runner": {
                        "repository_path": RUNNER_REPOSITORY_PATH.as_posix(),
                        "evidence_path": RUNNER_EVIDENCE_PATH.as_posix(),
                        "sha256": sha256_bytes(FROZEN_RUNNER_BYTES),
                    },
                    "analyzer": {
                        "repository_path": ANALYZER_REPOSITORY_PATH.as_posix(),
                        "evidence_path": ANALYZER_EVIDENCE_PATH.as_posix(),
                        "sha256": sha256_bytes(FROZEN_ANALYZER_BYTES),
                    },
                },
            },
            "workload": {
                "backend": "cpu-iosurface",
                "input_mode": "saturation",
                "diagnostics_enabled": False,
                "resolutions": list(analyzer.RESOLUTIONS),
                "frames": args.frames,
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
                "sample_timeout_seconds": args.sample_timeout_seconds,
            },
            "builds": builds,
        }
        write_json(output_directory / "metadata.json", metadata)
        result = analyzer.analyze(
            output_directory,
            verify_manifest=False,
            internal_inputs_only=True,
        )
        write_json(output_directory / "stats.json", result)
        write_checksums(output_directory)
        verified_result = analyzer.analyze(output_directory)
        if verified_result != result:
            raise RunError("post-manifest analysis changed the computed statistics")
        if json.loads((output_directory / "stats.json").read_text(encoding="utf-8")) != result:
            raise RunError("stored statistics differ from the verified result")
        verify_frozen_tools_unchanged()
        print(output_directory)
    except Exception:
        write_checksums(output_directory)
        raise
    finally:
        active_exception = sys.exc_info()[0] is not None
        tool_change_error: RunError | None = None
        try:
            verify_frozen_tools_unchanged()
        except RunError as error:
            tool_change_error = error
        if args.keep_worktrees:
            print(f"retained worktrees under {work_root}", file=sys.stderr)
        else:
            for path in worktrees.values():
                remove_worktree(repo, path)
            shutil.rmtree(work_root, ignore_errors=True)
        if tool_change_error is not None:
            if active_exception:
                print(str(tool_change_error), file=sys.stderr)
            else:
                raise tool_change_error


if __name__ == "__main__":
    main()
