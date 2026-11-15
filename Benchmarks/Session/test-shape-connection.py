#!/usr/bin/env python3
"""Loopback integration check: ordered bytes, bounded queues, private-file cleanup."""
import asyncio
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def test_ordered_bytes_and_private_configuration_cleanup(self):
        async def echo(reader, writer):
            try:
                while data := await reader.read(16_384):
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        server = await asyncio.start_server(echo, "127.0.0.1", 0)
        async with server:
            with tempfile.TemporaryDirectory(prefix="spice-relay-test-") as directory:
                root = Path(directory)
                connection, metrics = root / "input.vv", root / "metrics.json"
                connection.write_text("[virt-viewer]\ntype=spice\nhost=127.0.0.1\n"
                    f"tls-port={server.sockets[0].getsockname()[1]}\n"
                    "password=fixture-only\nca=fixture-only\nhost-subject=CN=fixture\n")
                child = await asyncio.create_subprocess_exec(
                    sys.executable, str(Path(__file__).with_name("shape-connection.py")),
                    str(connection), "--profile", "latency", "--metrics", str(metrics),
                    "--runtime-directory", str(root), stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                runtime = None
                try:
                    header = json.loads(await asyncio.wait_for(child.stdout.readline(), 5))
                    runtime = Path(header["connection_path"])
                    self.assertEqual(stat.S_IMODE(runtime.stat().st_mode), 0o600)
                    self.assertEqual(stat.S_IMODE(runtime.parent.stat().st_mode), 0o700)
                    self.assertIn("host-subject=CN=fixture", runtime.read_text())
                    self.assertNotIn("fixture-only", json.dumps(header))
                    port = int(next(line.split("=", 1)[1] for line in runtime.read_text().splitlines()
                        if line.startswith("tls-port=")))
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    payload = bytes(range(256)) * 2_048
                    writer.write(payload)
                    await writer.drain()
                    actual = await asyncio.wait_for(reader.readexactly(len(payload)), 10)
                    self.assertEqual(actual, payload)
                    writer.close()
                    await writer.wait_closed()
                finally:
                    if child.returncode is None:
                        child.terminate()
                    try:
                        await asyncio.wait_for(child.wait(), 5)
                    except TimeoutError:
                        child.kill()
                        await child.wait()
                self.assertEqual(child.returncode, 0)
                self.assertIsNotNone(runtime)
                self.assertFalse(runtime.exists())
                result = json.loads(metrics.read_text())
                self.assertEqual(result["up_bytes"], len(payload))
                self.assertEqual(result["down_bytes"], len(payload))
                self.assertLessEqual(result["peak_queued_chunks"], 16)


if __name__ == "__main__":
    unittest.main()
