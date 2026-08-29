#!/usr/bin/env python3

"""Validate and atomically append one normalized schema-2 input event."""

import fcntl
import json
import os
import re
import stat
import sys
import tempfile
from typing import Optional

MAXIMUM_RECORD_BYTES = 64 * 1024
MAXIMUM_FILE_BYTES = 16 * 1024 * 1024
UINT64_MAX = (1 << 64) - 1
UINT32_MAX = (1 << 32) - 1
UINT8_MAX = (1 << 8) - 1

METADATA_KEYS = ("pair_id", "version", "run_id", "order", "action_class", "token")
OPTIONAL_UINT64_KEYS = (
    "scheduled_ns",
    "host_input_ns",
    "send_started_ns",
    "send_completed_ns",
    "motion_ack_ns",
    "guest_received_ns",
    "guest_marker_drawn_ns",
    "display_receive_ns",
    "surface_ready_ns",
    "selected_revision_ready_ns",
    "selection_ns",
    "metal_commit_ns",
    "presented_ns",
    "surface_generation",
    "desktop_generation",
    "frame_revision",
    "delivery_sequence",
    "marker_revision",
)
CANONICAL_KEYS = (
    "schema_version",
    *METADATA_KEYS,
    *OPTIONAL_UINT64_KEYS,
    "display_channel_id",
    "surface_id",
    "marker_checksum",
    "valid",
    "invalid_reason",
)
EVIDENCE_FAILURES = {
    "invalid_pair_id",
    "invalid_version",
    "invalid_run_id",
    "invalid_token",
    "missing_scheduled",
    "missing_host_input",
    "missing_send_started",
    "missing_send_completed",
    "missing_guest_received",
    "missing_guest_marker_drawn",
    "missing_marker_revision",
    "missing_marker_checksum",
    "invalid_marker_checksum",
    "missing_display_receive",
    "missing_surface_ready",
    "missing_selected_revision_ready",
    "missing_selection",
    "missing_metal_commit",
    "missing_presented",
    "missing_display_channel_id",
    "missing_surface_id",
    "missing_frame_revision",
    "missing_surface_generation",
    "missing_desktop_generation",
    "missing_delivery_sequence",
    "non_monotonic_timestamps",
}


class InputEventError(Exception):
    def __init__(self, reason: str, exit_status: int = 1):
        super().__init__(reason)
        self.reason = reason
        self.exit_status = exit_status


def is_uint(value: object, maximum: int = UINT64_MAX) -> bool:
    return type(value) is int and 0 <= value <= maximum


def require_attribution(event: dict) -> None:
    if any(key not in event for key in METADATA_KEYS):
        raise InputEventError("unattributable", 2)
    if not isinstance(event["pair_id"], str) or not event["pair_id"]:
        raise InputEventError("unattributable", 2)
    if not isinstance(event["version"], str) or not event["version"]:
        raise InputEventError("unattributable", 2)
    if not isinstance(event["run_id"], str) or not event["run_id"]:
        raise InputEventError("unattributable", 2)
    if not is_uint(event["order"]):
        raise InputEventError("unattributable", 2)
    if event["action_class"] not in ("click", "key", "motion"):
        raise InputEventError("unattributable", 2)
    if not isinstance(event["token"], str) or re.fullmatch(r"[0-9a-f]{16}", event["token"]) is None:
        raise InputEventError("unattributable", 2)


def normalize(event: dict, expected_run_id: str) -> dict:
    require_attribution(event)
    if event["run_id"] != expected_run_id:
        raise InputEventError("run_id_mismatch", 2)
    schema_version = event.get("schema_version")
    if type(schema_version) is not int or schema_version != 2:
        raise InputEventError("unsupported_schema_version", 2)
    unknown = set(event) - set(CANONICAL_KEYS)
    if unknown:
        raise InputEventError("unknown_field", 2)

    normalized = {key: None for key in CANONICAL_KEYS}
    normalized.update({key: event.get(key) for key in CANONICAL_KEYS})
    normalized["schema_version"] = 2
    evidence_type_failure = None
    for key in OPTIONAL_UINT64_KEYS:
        value = normalized[key]
        if value is not None and not is_uint(value):
            normalized[key] = None
            evidence_type_failure = evidence_type_failure or f"invalid_field_type_{key}"
    if normalized["display_channel_id"] is not None and not is_uint(
        normalized["display_channel_id"], UINT8_MAX
    ):
        normalized["display_channel_id"] = None
        evidence_type_failure = evidence_type_failure or "invalid_field_type_display_channel_id"
    if normalized["surface_id"] is not None and not is_uint(
        normalized["surface_id"], UINT32_MAX
    ):
        normalized["surface_id"] = None
        evidence_type_failure = evidence_type_failure or "invalid_field_type_surface_id"
    marker_checksum = normalized["marker_checksum"]
    if marker_checksum is not None and not isinstance(marker_checksum, str):
        normalized["marker_checksum"] = None
        evidence_type_failure = evidence_type_failure or "invalid_field_type_marker_checksum"
    external_reason = normalized["invalid_reason"]
    if external_reason is not None and not isinstance(external_reason, str):
        external_reason = "invalid_field_type_invalid_reason"

    preferred_reason = (
        external_reason if external_reason is not None else evidence_type_failure
    )
    evidence_only_failure = validation_failure(normalized, None)
    if preferred_reason in EVIDENCE_FAILURES and evidence_only_failure is None:
        raise InputEventError("inconsistent_validation_fields", 2)
    normalized["invalid_reason"] = validation_failure(normalized, preferred_reason)
    normalized["valid"] = normalized["invalid_reason"] is None
    # Match Swift Codable's canonical wire form: nil optionals are omitted,
    # while schema, attribution metadata, and the derived valid bit remain.
    return {key: value for key, value in normalized.items() if value is not None}


def validation_failure(event: dict, external_reason: Optional[str]) -> Optional[str]:
    if external_reason is not None:
        return external_reason if external_reason else "invalid_reason_empty"

    required_evidence = (
        ("scheduled_ns", "missing_scheduled"),
        ("host_input_ns", "missing_host_input"),
        ("send_started_ns", "missing_send_started"),
        ("send_completed_ns", "missing_send_completed"),
        ("guest_received_ns", "missing_guest_received"),
        ("guest_marker_drawn_ns", "missing_guest_marker_drawn"),
        ("marker_revision", "missing_marker_revision"),
    )
    for key, reason in required_evidence:
        if event[key] is None:
            return reason
    checksum = event["marker_checksum"]
    if checksum is None:
        return "missing_marker_checksum"
    if re.fullmatch(r"[0-9a-f]{8}", checksum) is None:
        return "invalid_marker_checksum"
    for key, reason in (
        ("display_receive_ns", "missing_display_receive"),
        ("surface_ready_ns", "missing_surface_ready"),
        ("selected_revision_ready_ns", "missing_selected_revision_ready"),
        ("selection_ns", "missing_selection"),
        ("metal_commit_ns", "missing_metal_commit"),
        ("presented_ns", "missing_presented"),
        ("display_channel_id", "missing_display_channel_id"),
        ("surface_id", "missing_surface_id"),
        ("frame_revision", "missing_frame_revision"),
        ("surface_generation", "missing_surface_generation"),
        ("desktop_generation", "missing_desktop_generation"),
        ("delivery_sequence", "missing_delivery_sequence"),
    ):
        if event[key] is None:
            return reason

    host = [
        event["scheduled_ns"],
        event["host_input_ns"],
        event["send_started_ns"],
        event["send_completed_ns"],
    ]
    display = [
        event["send_started_ns"],
        event["display_receive_ns"],
        event["surface_ready_ns"],
        event["selected_revision_ready_ns"],
        event["selection_ns"],
        event["metal_commit_ns"],
        event["presented_ns"],
    ]
    guest = [event["guest_received_ns"], event["guest_marker_drawn_ns"]]
    if any(left > right for left, right in zip(host, host[1:])):
        return "non_monotonic_timestamps"
    if any(left > right for left, right in zip(display, display[1:])):
        return "non_monotonic_timestamps"
    if guest[0] > guest[1]:
        return "non_monotonic_timestamps"
    motion_ack = event["motion_ack_ns"]
    if motion_ack is not None and not (
        event["send_started_ns"] <= motion_ack <= event["presented_ns"]
    ):
        return "non_monotonic_timestamps"
    return None


def require_run_directory(path: str) -> tuple[str, str]:
    absolute = os.path.abspath(path)
    try:
        status = os.lstat(absolute)
    except OSError as error:
        raise InputEventError("run_directory_unavailable") from error
    if not stat.S_ISDIR(status.st_mode) or stat.S_ISLNK(status.st_mode):
        raise InputEventError("run_directory_unavailable")
    run_id = os.path.basename(absolute)
    configuration = os.path.join(absolute, "configuration.txt")
    try:
        configuration_status = os.lstat(configuration)
        if (
            not stat.S_ISREG(configuration_status.st_mode)
            or configuration_status.st_size < 0
            or configuration_status.st_size > MAXIMUM_RECORD_BYTES
        ):
            raise InputEventError("configuration_unavailable")
        descriptor = os.open(
            configuration, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        )
        try:
            opened_status = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened_status.st_mode)
                or opened_status.st_dev != configuration_status.st_dev
                or opened_status.st_ino != configuration_status.st_ino
                or opened_status.st_size != configuration_status.st_size
            ):
                raise InputEventError("configuration_unavailable")
            chunks = []
            remaining = MAXIMUM_RECORD_BYTES + 1
            while remaining:
                chunk = os.read(descriptor, min(remaining, 65536))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            configuration_bytes = b"".join(chunks)
            if len(configuration_bytes) != opened_status.st_size:
                raise InputEventError("configuration_unavailable")
        finally:
            os.close(descriptor)
        lines = configuration_bytes.decode("utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise InputEventError("configuration_unavailable") from error
    if lines.count("interaction_trace_schema=2") != 1:
        raise InputEventError("configuration_schema_mismatch")
    if lines.count(f"run_id={run_id}") != 1:
        raise InputEventError("configuration_run_id_mismatch")
    expected_path = f"interaction_trace_path={absolute}/input-events.jsonl"
    if lines.count(expected_path) != 1:
        raise InputEventError("configuration_path_mismatch")
    return absolute, run_id


def canonical_json_bytes(record: dict) -> bytes:
    return json.dumps(
        record, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def atomic_append(run_directory: str, expected_run_id: str, record: dict) -> None:
    output = os.path.join(run_directory, "input-events.jsonl")
    lock_path = os.path.join(run_directory, ".input-events.jsonl.lock")
    line = canonical_json_bytes(record) + b"\n"
    if len(line) > MAXIMUM_RECORD_BYTES:
        raise InputEventError("record_too_large")

    lock_descriptor = os.open(
        lock_path,
        os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        os.fchmod(lock_descriptor, 0o600)
        # POSIX record locking interoperates with the Swift writer's fcntl lock.
        fcntl.lockf(lock_descriptor, fcntl.LOCK_EX)
        existing = b""
        try:
            output_status = os.lstat(output)
            if stat.S_ISLNK(output_status.st_mode) or not stat.S_ISREG(output_status.st_mode):
                raise InputEventError("output_not_regular")
            if output_status.st_size > MAXIMUM_FILE_BYTES:
                raise InputEventError("output_too_large")
            descriptor = os.open(output, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
            try:
                opened_status = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(opened_status.st_mode)
                    or opened_status.st_dev != output_status.st_dev
                    or opened_status.st_ino != output_status.st_ino
                    or opened_status.st_size > MAXIMUM_FILE_BYTES
                ):
                    raise InputEventError("output_changed_during_open")
                chunks = []
                remaining = MAXIMUM_FILE_BYTES + 1
                while remaining:
                    chunk = os.read(descriptor, min(remaining, 65536))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    remaining -= len(chunk)
                existing = b"".join(chunks)
            finally:
                os.close(descriptor)
        except FileNotFoundError:
            pass
        if existing and not existing.endswith(b"\n"):
            raise InputEventError("invalid_existing_jsonl")
        existing_lines = existing.splitlines()
        for existing_line in existing_lines:
            if len(existing_line) + 1 > MAXIMUM_RECORD_BYTES:
                raise InputEventError("invalid_existing_jsonl")
            try:
                existing_event = json.loads(existing_line)
                if not isinstance(existing_event, dict):
                    raise ValueError
                normalized_existing = normalize(existing_event, expected_run_id)
            except (InputEventError, ValueError, json.JSONDecodeError, UnicodeDecodeError) as error:
                raise InputEventError("invalid_existing_jsonl") from error
            if existing_line != canonical_json_bytes(normalized_existing):
                raise InputEventError("invalid_existing_jsonl")
        if line[:-1] in existing_lines:
            directory_descriptor = os.open(run_directory, os.O_RDONLY | os.O_CLOEXEC)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
            return
        if len(existing) + len(line) > MAXIMUM_FILE_BYTES:
            raise InputEventError("output_too_large")

        descriptor, temporary = tempfile.mkstemp(
            prefix=".input-events.jsonl.", suffix=".tmp", dir=run_directory
        )
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb", closefd=True) as destination:
                destination.write(existing)
                destination.write(line)
                destination.flush()
                os.fsync(destination.fileno())
            os.replace(temporary, output)
            directory_descriptor = os.open(run_directory, os.O_RDONLY | os.O_CLOEXEC)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        except BaseException:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
    finally:
        os.close(lock_descriptor)


def main() -> int:
    if len(sys.argv) != 2:
        print("PERF_INPUT_EVENT_ERROR reason=usage", file=sys.stderr)
        return 2
    try:
        run_directory, expected_run_id = require_run_directory(sys.argv[1])
        raw = sys.stdin.buffer.read(MAXIMUM_RECORD_BYTES + 1)
        if len(raw) > MAXIMUM_RECORD_BYTES:
            raise InputEventError("record_too_large", 2)
        try:
            event = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise InputEventError("malformed_json", 2) from error
        if not isinstance(event, dict):
            raise InputEventError("malformed_json", 2)
        normalized = normalize(event, expected_run_id)
        atomic_append(run_directory, expected_run_id, normalized)
        reason = normalized.get("invalid_reason") or "none"
        print(
            "PERF_INPUT_EVENT_COLLECTED "
            f"valid={'true' if normalized['valid'] else 'false'} reason={reason}"
        )
        return 0
    except InputEventError as error:
        print(f"PERF_INPUT_EVENT_ERROR reason={error.reason}", file=sys.stderr)
        return error.exit_status
    except OSError:
        print("PERF_INPUT_EVENT_ERROR reason=file_operation_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
