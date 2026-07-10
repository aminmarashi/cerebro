"""Chronological history for successful ``cerebro improve`` runs."""

import json
import os
import sys
import tempfile

try:
    import fcntl
except ImportError:  # pragma: no cover - non-Unix platforms
    fcntl = None


def _load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {"runs": [], "next_id": 1}


def _atomic_write(path, data):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _locked_update(path, mutate):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path + ".lock", "w", encoding="utf-8") as lock:
        if fcntl:
            fcntl.flock(lock, fcntl.LOCK_EX)
        data = mutate(_load(path))
        _atomic_write(path, data)


def add_run(path, run_type, timestamp, findings_count, verdict, utility):
    result = []

    def mutate(data):
        number = int(data.get("next_id", 1))
        run_id = "improve-%04d" % number
        data.setdefault("runs", []).append({
            "run_id": run_id,
            "ts": timestamp,
            "type": run_type,
            "findings_count": int(findings_count),
            "verdict": verdict,
            "utility": float(utility) if utility != "" else None,
        })
        data["next_id"] = number + 1
        result.append(run_id)
        return data

    _locked_update(path, mutate)
    return result[0]


def last_timestamp(path):
    runs = _load(path).get("runs", [])
    return runs[-1].get("ts", "") if runs else ""


def fast_count_since_last_meta(path):
    count = 0
    for run in reversed(_load(path).get("runs", [])):
        if run.get("type") == "meta":
            break
        if run.get("type") == "fast":
            count += 1
    return count


def list_runs(path):
    for run in _load(path).get("runs", []):
        sys.stdout.write("\t".join([
            run.get("run_id", ""),
            run.get("type", ""),
            run.get("ts", ""),
            run.get("verdict", ""),
            str(run.get("findings_count", 0)),
            str(run.get("utility", "")),
        ]) + "\n")
