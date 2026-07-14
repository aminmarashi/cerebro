"""Launch a command in a process session independent of the caller.

The short-lived launcher starts a monitor in a new session and exits. The
monitor runs the command, appends its output to the requested log, and records
the final exit code. This prevents an agent harness from reaping the command
when its own finite-lived background task is cleaned up.
"""

import json
import os
import subprocess
import sys
import time


def write_atomic(path, value):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as fh:
        fh.write(value)
    os.replace(tmp, path)


def write_status(paths, value):
    for path in paths:
        write_atomic(path, value)


def monitor(output, output_status, job_status, command):
    statuses = (output_status, job_status)
    write_status(statuses, "running\n")
    try:
        with open(output, "ab", buffering=0) as log:
            rc = subprocess.call(
                command,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                close_fds=True,
            )
    except Exception as exc:
        with open(output, "ab", buffering=0) as log:
            log.write(f"cerebro detach: launch failed: {exc}\n".encode())
        rc = 127
    write_status(statuses, f"{rc}\n")


def launch(output, status, pid_path, job_file, job_id, label, command):
    parent = os.path.dirname(output)
    if parent:
        os.makedirs(parent, exist_ok=True)
    open(output, "wb").close()
    job_status = f"{job_file}.status"
    job_pid = f"{job_file}.pid"
    write_status((status, job_status), "starting\n")

    proc = subprocess.Popen(
        [
            sys.executable,
            os.path.abspath(__file__),
            "--monitor",
            output,
            status,
            job_status,
            *command,
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    for path in (pid_path, job_pid):
        write_atomic(path, f"{proc.pid}\n")
    job = {
        "id": job_id,
        "command": label,
        "output": output,
        "status": job_status,
        "pid_file": job_pid,
        "output_status": status,
        "output_pid_file": pid_path,
        "pid": proc.pid,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_atomic(job_file, json.dumps(job, indent=2) + "\n")
    print(f"cerebro: detached job {job_id} (pid {proc.pid})")
    print(f"  output: {output}")
    print(f"  status: {status} (running, then the numeric exit code)")
    print(f"  notify: cerebro wait {job_id}")
    print(f"  cancel: cerebro cancel {job_id}")


if len(sys.argv) >= 2 and sys.argv[1] == "--monitor":
    if len(sys.argv) < 6:
        sys.exit("detach_process: missing monitor arguments")
    monitor(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
elif len(sys.argv) >= 8:
    launch(
        sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
        sys.argv[6], sys.argv[7:],
    )
else:
    sys.exit("detach_process: missing arguments")
