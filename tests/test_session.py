"""Regression checks for the clock's wall time and cursor protocol."""

import asyncio
import importlib.util
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
from zoneinfo import ZoneInfo

SOURCE = Path(__file__).resolve().parents[1] / "session.py"
SPEC = importlib.util.spec_from_file_location("desktop_clock_session", SOURCE)
session_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(session_module)


class SessionTest(unittest.IsolatedAsyncioTestCase):
    async def test_midnight_resume_and_clock_correction(self):
        session = session_module.Session()
        session.zone = ZoneInfo("UTC")
        midnight = 1794528000 * 10**9
        with patch.object(session_module, "send") as send:
            try:
                changes = ((-60, 0), (0, 0), (60, 0), (120, 120), (60, 120), (360, 120))
                for seconds, slept in changes:
                    with patch.object(session_module.time, "time_ns", return_value=midnight + seconds * 10**9), \
                         patch.object(session_module.time, "monotonic_ns", return_value=0), \
                         patch.object(session_module.time, "clock_gettime_ns", return_value=slept * 10**9):
                        session.publish_clock()
                packets = [call.kwargs for call in send.call_args_list]
                self.assertEqual([packet["time"] for packet in packets],
                                 ["23:59", "00:00", "00:01", "00:02", "00:01", "00:06"])
                self.assertEqual([packet["animate"] for packet in packets],
                                 [False, True, True, False, False, False])
            finally:
                if session.timer is not None:
                    session.timer.cancel()

    async def test_pointer_waits_for_complete_response_and_bounds_size(self):
        async def response(reader, writer):
            try:
                self.assertEqual(await reader.readexactly(11), b"j/cursorpos")
                parts = next(replies)
                for part in parts:
                    writer.write(part)
                    await writer.drain()
                    await asyncio.sleep(0)
            finally:
                writer.close()
                await writer.wait_closed()

        replies = iter((
            (b'{"x":-21,', b'"y":80}'),
            (b'{"x":NaN,"y":80}',),
            (b" " * 1025,),
        ))
        session = session_module.Session()
        with TemporaryDirectory() as directory:
            session.socket = str(Path(directory) / "hypr.sock")
            server = await asyncio.start_unix_server(response, session.socket)
            async with server:
                self.assertEqual(await session.position(), (-21, 80))
                self.assertIsNone(await session.position())
                self.assertIsNone(await session.position())

    async def test_cursor_pause_clears_hover_and_stops_requests(self):
        session = session_module.Session()
        session.socket = "test-socket"
        session.configure({"hz": 30})
        with patch.object(session, "position", return_value=(-100, 60)) as position, \
             patch.object(session_module, "send") as send:
            task = asyncio.create_task(session.cursor())
            try:
                async with asyncio.timeout(1):
                    while session.pointer is None:
                        await asyncio.sleep(0.001)
                    session.configure({"hz": 0})
                    while session.pointer is not None:
                        await asyncio.sleep(0.001)
                calls = position.call_count
                await asyncio.sleep(0.04)
                self.assertEqual(position.call_count, calls)
                self.assertEqual([call.kwargs for call in send.call_args_list],
                                 [{"cursor": (-100, 60)}, {"cursor": None}])
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_input_idle_keeps_pointer_and_resumes_polling_immediately(self):
        session = session_module.Session()
        session.socket = "test-socket"
        session.configure({"hz": 30, "inputIdle": True})
        next_position = asyncio.Event()

        async def position():
            next_position.set()
            return (24, 60)

        with patch.object(session, "position", side_effect=position) as request, \
             patch.object(session_module, "send") as send:
            task = asyncio.create_task(session.cursor())
            try:
                await asyncio.wait_for(next_position.wait(), 1)
                next_position.clear()
                await asyncio.sleep(0.075)
                self.assertEqual(request.call_count, 1)
                self.assertEqual(session.pointer, (24, 60))
                session.configure({"inputIdle": False})
                await asyncio.wait_for(next_position.wait(), 0.1)
                self.assertEqual([call.kwargs for call in send.call_args_list], [{"cursor": (24, 60)}])
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
