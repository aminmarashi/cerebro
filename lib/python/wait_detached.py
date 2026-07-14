"""Wait silently for a detached Cerebro command's final exit status."""

import os
import subprocess
import sys
import time


if len(sys.argv) != 3:
    sys.exit("wait_detached: expected <status-path> <pid-path>")

status_path, pid_path = sys.argv[1:]


def read(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def write_atomic(path, value):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as fh:
        fh.write(value)
    os.replace(tmp, path)


def monitor_alive(pid, status):
    try:
        os.kill(int(pid), 0)
    except (OSError, ValueError):
        return False
    try:
        command = subprocess.check_output(
            ["ps", "-p", str(int(pid)), "-o", "command="], text=True
        )
    except (subprocess.CalledProcessError, ValueError):
        return False
    return "detach_process.py --monitor" in command and status in command


while True:
    value = read(status_path)
    if value in ("starting", "running"):
        pid = read(pid_path)
        if not pid or not monitor_alive(pid, status_path):
            # The monitor writes the final status before exiting. Re-read after
            # a short grace period to distinguish that atomic handoff from a
            # monitor lost to reboot, SIGKILL, or external process cleanup.
            time.sleep(0.5)
            if read(status_path) in ("starting", "running") and (
                not pid or not monitor_alive(pid, status_path)
            ):
                write_atomic(status_path, "125\n")
                sys.stderr.write(
                    f"cerebro: detached monitor {pid or 'unknown'} disappeared; "
                    "recorded exit 125\n"
                )
                sys.exit(125)
        time.sleep(0.5)
        continue
    try:
        rc = int(value)
    except ValueError:
        pid = read(pid_path) or "unknown"
        sys.stderr.write(
            f"cerebro: detached monitor {pid} left invalid status: "
            f"{value or '(missing)'}\n"
        )
        sys.exit(125)
    print(f"cerebro: detached child finished (exit {rc})")
    sys.exit(rc)
