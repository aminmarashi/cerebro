# Utility estimation: scan the trace corpus under $CEREBRO_HOME/sessions/
# and compute a session-quality proxy U in [0, 1]. Higher = healthier runs.
#
# The proxy is a weighted composite of four signals already in the corpus:
#   w1 * (1 - child_failure_rate)   -- fewer child failures/stalls
#   w2 * (1 - review_rounds_norm)   -- fewer review rounds until quiet
#   w3 * (1 - correction_density)   -- fewer user corrections (learn-notes)
#   w4 * (1 - improve_stagnation)   -- improve runs not re-finding same issues
#
# Usage: improve_utility.py <cerebro_home> [since_ts]
#   <since_ts>  -- ISO timestamp; only sessions created after this are scored
#                  (empty = score all sessions). Used to compute delta_u.
# Prints a single float in [0, 1].

import json, os, sys, glob, collections

def _scan_transcript(path):
    """Return (events, n_prompts) for one transcript.jsonl."""
    events = collections.Counter()
    n_prompts = 0
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                kind = obj.get("kind", "")
                if kind == "prompt":
                    n_prompts += 1
                elif kind == "event":
                    what = obj.get("what", "")
                    events[what] += 1
    except Exception:
        pass
    return events, n_prompts

def _child_failures(session_dir):
    """Count child logs that look like failures (non-zero exit events)."""
    n_fail = 0
    n_total = 0
    children_dir = os.path.join(session_dir, "children")
    for f in glob.glob(os.path.join(children_dir, "*.jsonl")):
        n_total += 1
        try:
            with open(f) as fh:
                lines = fh.readlines()
        except Exception:
            continue
        has_output = False
        for line in lines[-5:]:
            try:
                obj = json.loads(line.strip())
            except Exception:
                continue
            if obj.get("type") == "assistant" or obj.get("role") == "assistant":
                has_output = True
        if not has_output and lines:
            n_fail += 1
    return n_fail, max(n_total, 1)

def compute_utility(cerebro_home, since_ts=""):
    sessions_dir = os.path.join(cerebro_home, "sessions")
    if not os.path.isdir(sessions_dir):
        return 0.5  # neutral when no data

    total_sessions = 0
    total_child_fails = 0
    total_children = 0
    total_review_rounds = 0
    total_learn_notes = 0
    total_prompts = 0
    improve_count = 0

    for entry in os.listdir(sessions_dir):
        sess_dir = os.path.join(sessions_dir, entry)
        if not os.path.isdir(sess_dir):
            continue
        # Filter by since_ts if provided: check metadata.json created_at
        if since_ts:
            meta = os.path.join(sess_dir, "metadata.json")
            created = ""
            try:
                with open(meta) as fh:
                    m = json.load(fh)
                    created = m.get("created_at", "")
            except Exception:
                pass
            if created and created < since_ts:
                continue

        total_sessions += 1
        transcript = os.path.join(sess_dir, "transcript.jsonl")
        events, n_prompts = _scan_transcript(transcript)
        total_prompts += n_prompts
        total_learn_notes += events.get("learn_note", 0)
        total_review_rounds += events.get("review_written", 0) + events.get("review_started", 0)
        # Child failures: use only the file-scan heuristic (single source for
        # both numerator and denominator) to avoid a numerator/denominator
        # mismatch when events exist but child files don't.
        cf, ct = _child_failures(sess_dir)
        total_child_fails += cf
        total_children += ct
        # Stagnation: count improve.md files in this session's improvements dir.
        imp_dir = os.path.join(sess_dir, "improvements")
        if os.path.isdir(imp_dir):
            improve_count += len(glob.glob(os.path.join(imp_dir, "improve.md")))

    if total_sessions == 0:
        return 0.5  # neutral when no sessions in window

    # Guard: sessions with no transcript data (empty corpus) should score
    # neutral (0.5), not perfect (1.0).  Each density term uses 0.5 when its
    # denominator is 0.
    if total_prompts == 0:
        return 0.5

    child_failure_rate = total_child_fails / max(total_children, 1)
    review_density = total_review_rounds / max(total_prompts, 1)
    correction_density = total_learn_notes / max(total_prompts, 1)
    improve_stagnation = min(improve_count / 10.0, 1.0)

    w1, w2, w3, w4 = 0.35, 0.25, 0.25, 0.15
    u = (w1 * (1.0 - min(child_failure_rate, 1.0))
         + w2 * (1.0 - min(review_density, 1.0))
         + w3 * (1.0 - min(correction_density, 1.0))
         + w4 * (1.0 - improve_stagnation))
    return round(u, 4)

if __name__ == "__main__":
    home = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CEREBRO_HOME", "")
    since = sys.argv[2] if len(sys.argv) > 2 else ""
    if not home:
        sys.stdout.write("0.5\n")
        sys.exit(0)
    print(compute_utility(home, since))