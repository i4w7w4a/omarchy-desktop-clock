"""Read the compositor pointer and publish minute boundaries for Omarchy Shell."""

import asyncio
import json
import os
import re
import socket
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def send(**message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


class Session:
    def __init__(self):
        self.loop = asyncio.get_running_loop()
        self.closed = asyncio.Event()
        self.input = bytearray()
        self.hz = 0
        self.input_idle = False
        self.pointer = None
        self.cursor_changed = asyncio.Event()
        self.zone_name = "system"
        self.zone = None
        self.zone_valid = True
        self.local_zone_signature = None
        self.last_minute = None
        self.last_text = None
        self.suspend_offset = None
        self.timer = None
        self.clock_fd = None
        self.boundary = None
        self.readings = []
        self.next_report = self.loop.time() + 2
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        instance = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        self.socket = (
            str(Path(runtime) / "hypr" / instance / ".socket.sock")
            if runtime and re.fullmatch(r"[A-Za-z0-9_.-]+", instance) and instance not in {".", ".."}
            else None
        )

    def publish_clock(self, force=False):
        now_ns = time.time_ns()
        minute = now_ns // 60_000_000_000
        suspend_offset = time.clock_gettime_ns(time.CLOCK_BOOTTIME) - time.monotonic_ns()
        resumed = self.suspend_offset is not None and suspend_offset - self.suspend_offset > 100_000_000
        self.suspend_offset = suspend_offset
        try:
            local = os.stat("/etc/localtime")
            signature = (local.st_dev, local.st_ino, local.st_mtime_ns)
        except OSError:
            signature = ()
        zone_changed = signature != self.local_zone_signature
        if zone_changed:
            self.local_zone_signature = signature
            time.tzset()
        display = datetime.fromtimestamp(now_ns // 1_000_000_000, self.zone).strftime("%H:%M")
        if force or resumed or minute != self.last_minute or display != self.last_text:
            natural = (
                not force and not resumed and not zone_changed and self.last_minute is not None
                and minute == self.last_minute + 1
                and now_ns % 60_000_000_000 < 1_500_000_000
                and (int(display[:2]) * 60 + int(display[3:])
                     - int(self.last_text[:2]) * 60 - int(self.last_text[3:])) % 1440 == 1
            )
            send(time=display, animate=natural, zoneAvailable=self.zone_valid)
            self.last_minute = minute
            self.last_text = display
        if self.clock_fd is not None and self.boundary != minute + 1:
            self.boundary = minute + 1
            os.timerfd_settime_ns(
                self.clock_fd,
                flags=os.TFD_TIMER_ABSTIME | os.TFD_TIMER_CANCEL_ON_SET,
                initial=self.boundary * 60_000_000_000,
            )
        if self.timer is not None:
            self.timer.cancel()
        # Also catches a change of the local zone without a clock adjustment.
        self.timer = self.loop.call_later(1, self.publish_clock)

    def clock_ready(self):
        try:
            os.read(self.clock_fd, 8)
        except BlockingIOError:
            return
        except OSError:
            self.boundary = None
            self.publish_clock(force=True)
            return
        self.publish_clock()

    def configure(self, command):
        if not isinstance(command, dict):
            return
        hz = command.get("hz", self.hz)
        if type(hz) is int and (hz == 0 or 15 <= hz <= 60) and hz != self.hz:
            self.hz = hz
            if hz == 0 and self.pointer is not None:
                self.pointer = None
                send(cursor=None)
            self.cursor_changed.set()
        idle = command.get("inputIdle", self.input_idle)
        if type(idle) is bool and idle != self.input_idle:
            self.input_idle = idle
            self.cursor_changed.set()
        name = command.get("zone", self.zone_name)
        if (isinstance(name, str) and len(name) <= 96 and name != self.zone_name
                and re.fullmatch(r"[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+)*", name)):
            try:
                zone = None if name == "system" else ZoneInfo(name)
                self.zone_valid = True
            except (ValueError, ZoneInfoNotFoundError):
                zone = None
                self.zone_valid = False
            self.zone_name = name
            self.zone = zone
            self.publish_clock(force=True)

    def read_input(self):
        chunk = os.read(sys.stdin.fileno(), 4096)
        if not chunk:
            self.closed.set()
            return
        self.input.extend(chunk)
        if len(self.input) > 8192:
            self.input.clear()
            return
        while (end := self.input.find(b"\n")) >= 0:
            line = bytes(self.input[:end])
            del self.input[:end + 1]
            try:
                self.configure(json.loads(line))
            except (UnicodeError, ValueError):
                pass

    async def position(self):
        # Each Hyprland request gets one short reply and a closed connection.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.setblocking(False)
            await self.loop.sock_connect(connection, self.socket)
            await self.loop.sock_sendall(connection, b"j/cursorpos")
            response = bytearray()
            while len(response) <= 1024:
                chunk = await self.loop.sock_recv(connection, 1025 - len(response))
                if not chunk:
                    break
                response.extend(chunk)
            if len(response) > 1024:
                return None
        point = json.loads(response)
        if not isinstance(point, dict):
            return None
        x, y = point.get("x"), point.get("y")
        if not all(type(n) in (int, float) and abs(n) < 1_000_000 for n in (x, y)):
            return None
        return (x, y)

    async def cursor(self):
        while True:
            self.cursor_changed.clear()
            if not self.hz or not self.socket:
                if self.pointer is not None:
                    self.pointer = None
                    send(cursor=None)
                self.readings.clear()
                await self.cursor_changed.wait()
                continue
            started = self.loop.time()
            try:
                async with asyncio.timeout(0.085):
                    point = await self.position()
            except (OSError, ValueError, TimeoutError):
                point = None
            duration = self.loop.time() - started
            if not self.hz:
                continue
            if point is not None:
                self.readings.append(duration * 1000)
            if point != self.pointer:
                self.pointer = point
                send(cursor=point)
            if self.loop.time() >= self.next_report:
                if self.readings:
                    ordered = sorted(self.readings)
                    send(ipc={"samples": len(ordered), "p50Ms": round(ordered[len(ordered) // 2], 3),
                              "p95Ms": round(ordered[int((len(ordered) - 1) * 0.95)], 3)})
                self.readings.clear()
                self.next_report = self.loop.time() + 2
            # Wayland wakes us immediately on input. Keep a slow check for
            # compositor warps that do not generate input activity.
            interval = 0.25 if self.input_idle or point is None else 1 / max(1, self.hz)
            try:
                await asyncio.wait_for(self.cursor_changed.wait(), max(0, interval - duration))
            except TimeoutError:
                pass

    async def run(self):
        try:
            self.clock_fd = os.timerfd_create(time.CLOCK_REALTIME, flags=os.TFD_NONBLOCK | os.TFD_CLOEXEC)
        except (AttributeError, OSError):
            self.clock_fd = None
        if self.clock_fd is not None:
            self.loop.add_reader(self.clock_fd, self.clock_ready)
        self.loop.add_reader(sys.stdin.fileno(), self.read_input)
        task = asyncio.create_task(self.cursor())
        try:
            send(ready=True)
            self.publish_clock(force=True)
            await self.closed.wait()
        finally:
            task.cancel()
            self.loop.remove_reader(sys.stdin.fileno())
            if self.clock_fd is not None:
                self.loop.remove_reader(self.clock_fd)
                os.close(self.clock_fd)
            if self.timer is not None:
                self.timer.cancel()


async def main():
    await Session().run()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except BrokenPipeError:
        pass
