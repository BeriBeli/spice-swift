#!/usr/bin/env python3
"""Bounded loopback byte-stream shaping for an explicitly supplied TLS .vv.

TLS stays end-to-end. A private, temporary connection file preserves the CA and
complete pinned subject; only its address changes. It is removed on exit. This
models delay/jitter and an aggregate directional byte rate, not IP packet loss.
"""
import argparse
import asyncio
import configparser
import contextlib
import json
import os
from pathlib import Path
import random
import signal
import tempfile

PROFILES = {
    "baseline": (0, 0, 0),
    "latency": (50, 20, 20_000_000),
    "bandwidth": (25, 10, 2_000_000),
}
CHUNK = 16_384
QUEUE_LIMIT = 16


class RateBudget:
    def __init__(self, bits_per_second):
        self.bytes_per_second = bits_per_second / 8
        self.next_time = 0
        self.lock = asyncio.Lock()

    async def admit(self, size):
        if not self.bytes_per_second:
            return
        loop = asyncio.get_running_loop()
        async with self.lock:
            now = loop.time()
            due = max(now, self.next_time)
            self.next_time = due + size / self.bytes_per_second
        await asyncio.sleep(max(0, due - loop.time()))


async def copy_stream(reader, writer, delay_ms, jitter_ms, budget, rng, metrics, direction):
    queue = asyncio.Queue(maxsize=QUEUE_LIMIT)

    async def read_chunks():
        previous_due = 0
        loop = asyncio.get_running_loop()
        while data := await reader.read(CHUNK):
            delay = max(0, delay_ms + rng.uniform(-jitter_ms, jitter_ms)) / 1000
            due = max(previous_due, loop.time() + delay)
            previous_due = due
            await queue.put((due, data))
            metrics["peak_queued_chunks"] = max(metrics["peak_queued_chunks"], queue.qsize())
        await queue.put((0, b""))

    async def write_chunks():
        loop = asyncio.get_running_loop()
        while True:
            due, data = await queue.get()
            if not data:
                if writer.can_write_eof():
                    writer.write_eof()
                return
            await asyncio.sleep(max(0, due - loop.time()))
            await budget.admit(len(data))
            writer.write(data)
            await writer.drain()
            metrics[direction + "_bytes"] += len(data)

    async with asyncio.TaskGroup() as group:
        group.create_task(read_chunks())
        group.create_task(write_chunks())


async def serve_connection(reader, writer, host, port, profile, budgets, sequence, metrics):
    upstream = None
    try:
        remote, upstream = await asyncio.open_connection(host, port)
        metrics["connections"] += 1
        delay, jitter, _ = profile
        async with asyncio.TaskGroup() as group:
            group.create_task(copy_stream(reader, upstream, delay, jitter, budgets[0],
                random.Random(sequence * 2), metrics, "up"))
            group.create_task(copy_stream(remote, writer, delay, jitter, budgets[1],
                random.Random(sequence * 2 + 1), metrics, "down"))
    except (OSError, ExceptionGroup):
        metrics["connection_errors"] += 1
    finally:
        for stream in [writer, upstream]:
            if stream:
                stream.close()
                with contextlib.suppress(OSError):
                    await stream.wait_closed()


async def main(args):
    raw = args.connection.read_text(encoding="utf-8-sig")
    config = configparser.ConfigParser(interpolation=None, strict=True)
    config.read_string(raw)
    section = config["virt-viewer"]
    # Refuse to turn hostname validation into an IP-address exception. The
    # existing full-subject CA policy is preserved byte-for-byte in the copy.
    if not section.get("ca") or not section.get("host-subject"):
        raise ValueError("requires_existing_CA_and_complete_subject_pin")
    host, port = section["host"], int(section["tls-port"])
    if not host or not 0 < port < 65536:
        raise ValueError("invalid_endpoint")
    profile = PROFILES[args.profile]
    budgets = (RateBudget(profile[2]), RateBudget(profile[2]))
    metrics = {"connections": 0, "connection_errors": 0, "up_bytes": 0,
        "down_bytes": 0, "peak_queued_chunks": 0}
    tasks = set()
    sequence = 0

    def accepted(reader, writer):
        nonlocal sequence
        sequence += 1
        task = asyncio.create_task(serve_connection(reader, writer, host, port,
            profile, budgets, sequence, metrics))
        tasks.add(task)
        task.add_done_callback(tasks.discard)

    server = await asyncio.start_server(accepted, "127.0.0.1", 0)
    local_port = server.sockets[0].getsockname()[1]
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in [signal.SIGINT, signal.SIGTERM]:
        loop.add_signal_handler(sig, stop.set)
    # tempfile owns a 0700 directory; the only credential-bearing file is 0600.
    with tempfile.TemporaryDirectory(prefix="spice-shaped-", dir=args.runtime_directory) as work:
        connection = Path(work) / "relay.vv"
        section_active = False
        lines = []
        for line in raw.splitlines(keepends=True):
            stripped = line.strip()
            if stripped.startswith("["):
                section_active = stripped.lower() == "[virt-viewer]"
            key = stripped.partition("=")[0].strip().lower()
            if section_active and key == "host":
                line = "host=127.0.0.1\n"
            elif section_active and key == "tls-port":
                line = f"tls-port={local_port}\n"
            lines.append(line)
        descriptor = os.open(connection, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as file:
            file.write("".join(lines))
        print(json.dumps({"connection_path": str(connection), "profile": args.profile,
            "one_way_delay_ms": profile[0], "jitter_ms": profile[1],
            "aggregate_directional_bits_per_second": profile[2],
            "tls": "end_to_end_CA_and_complete_subject_pin"}), flush=True)
        try:
            await stop.wait()
        finally:
            server.close()
            await server.wait_closed()
            for task in tuple(tasks):
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            connection.unlink(missing_ok=True)
            args.metrics.write_text(json.dumps(metrics, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("connection", type=Path)
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--metrics", type=Path, required=True)
    parser.add_argument("--runtime-directory", type=Path)
    arguments = parser.parse_args()
    try:
        asyncio.run(main(arguments))
    except (OSError, ValueError, KeyError, configparser.Error):
        raise SystemExit("shape_connection_failed")
