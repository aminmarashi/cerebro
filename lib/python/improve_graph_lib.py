# Shared improvement-graph library. The graph is a JSON file
# ($CEREBRO_HOME/improvement-graph.json) tracking every cerebro improve run
# as a DAG node, so the two-timescale loop can measure meta-productivity and
# decide when the slow (meta) loop should fire. All writes take an exclusive
# flock on a sidecar .lock file and rewrite the JSON atomically, mirroring
# child_store_lib.py.  _load is called inside the lock (read-modify-write
# is atomic), matching child_store_lib.store_upsert.

import json, sys, os, tempfile
try:
    import fcntl
    _HAVE_FCNTL = True
except Exception:
    _HAVE_FCNTL = False

def _load(f):
    try:
        with open(f) as fh:
            return json.load(fh)
    except Exception:
        return {"nodes": [], "next_id": 1}

def _atomic_write(f, data):
    d = os.path.dirname(f) or "."
    fd, tmp = tempfile.mkstemp(dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, f)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass

def _locked_update(f, mutate):
    """Take the flock, load, mutate(data) -> data, atomically write.
    Mirrors child_store_lib.store_upsert: _load is inside the lock so
    concurrent add-node / update-utility calls never clobber each other."""
    lf = open(f + ".lock", "w")
    try:
        if _HAVE_FCNTL:
            fcntl.flock(lf, fcntl.LOCK_EX)
        data = _load(f)
        data = mutate(data)
        if data is not None:
            _atomic_write(f, data)
    finally:
        try:
            if _HAVE_FCNTL:
                fcntl.flock(lf, fcntl.LOCK_UN)
        except OSError:
            pass
        lf.close()

def add_node(f, parent, node_type, ts, overlay_hash, meta_hash,
             findings_count, accepted_count, verdict, utility_before):
    def _mutate(data):
        nid = data.get("next_id", 1)
        node_id = "imp-%04d" % nid
        node = {
            "node_id": node_id,
            "parent": parent,
            "ts": ts,
            "type": node_type,           # "fast" or "meta"
            "overlay_hash": overlay_hash,
            "meta_hash": meta_hash,
            "findings_count": int(findings_count),
            "accepted_count": int(accepted_count),
            "verdict": verdict,
            "utility_before": float(utility_before) if utility_before != "" else None,
            "utility_after": None,
            "delta_u": None,
            "selections": 0,
        }
        data.setdefault("nodes", []).append(node)
        data["next_id"] = nid + 1
        return data
    node_id_holder = []
    def _mutate_and_capture(data):
        data = _mutate(data)
        # capture the node_id for return
        nodes = data.get("nodes", [])
        if nodes:
            node_id_holder.append(nodes[-1].get("node_id", ""))
        return data
    _locked_update(f, _mutate_and_capture)
    return node_id_holder[0] if node_id_holder else ""

def update_utility(f, utility):
    """Set utility_after + delta_u on the last FAST node (the one whose
    task-skill effect is now visible in new sessions).  Meta nodes are
    composites of the same window and don't need separate measurement."""
    if utility == "":
        return
    u = float(utility)
    def _mutate(data):
        for node in reversed(data.get("nodes", [])):
            if node.get("type") == "fast":
                node["utility_after"] = u
                if node.get("utility_before") is not None:
                    node["delta_u"] = u - node["utility_before"]
                break
        return data
    _locked_update(f, _mutate)

def increment_selections(f, node_id):
    """Increment the selections counter on <node_id> (frontier selection
    visitation cooling: N = 1/(1+selections))."""
    def _mutate(data):
        for node in data.get("nodes", []):
            if node.get("node_id") == node_id:
                node["selections"] = node.get("selections", 0) + 1
                break
        return data
    _locked_update(f, _mutate)

def last_meta_node_id(f):
    data = _load(f)
    for node in reversed(data.get("nodes", [])):
        if node.get("type") == "meta":
            return node.get("node_id") or ""
    return ""

def fast_count_since_last_meta(f):
    data = _load(f)
    count = 0
    for node in reversed(data.get("nodes", [])):
        if node.get("type") == "meta":
            break
        if node.get("type") == "fast":
            count += 1
    return count

def last_node_id(f):
    data = _load(f)
    nodes = data.get("nodes", [])
    return nodes[-1].get("node_id", "") if nodes else ""

def list_nodes(f):
    data = _load(f)
    for n in data.get("nodes", []):
        sys.stdout.write("\t".join([
            n.get("node_id", ""), n.get("parent", "") or "",
            n.get("type", ""), n.get("ts", ""),
            n.get("verdict", ""),
            str(n.get("findings_count", 0)),
            str(n.get("accepted_count", 0)),
            str(n.get("utility_before", "")),
            str(n.get("utility_after", "")),
            str(n.get("delta_u", "")),
            str(n.get("selections", 0)),
        ]) + "\n")

def _meta_productivity_from_data(data, node_id):
    """Mean delta_u over the children of <node_id>. 0 if no children."""
    deltas = [n.get("delta_u") for n in data.get("nodes", [])
              if n.get("parent") == node_id and n.get("delta_u") is not None]
    if not deltas:
        return 0.0
    return sum(deltas) / len(deltas)

def best_frontier(f, eta1, eta2, eta3):
    """Score each fast-loop node by eta1*U + eta2*P_hat + eta3*N and return
    the node_id with the highest score. U is utility_after (0 if unknown),
    P_hat is mean child delta_u, N is 1/(1+selections)."""
    data = _load(f)
    best_id, best_score = "", -1.0
    for n in data.get("nodes", []):
        if n.get("type") != "fast":
            continue
        u = n.get("utility_after")
        u = float(u) if u is not None else 0.0
        p = _meta_productivity_from_data(data, n.get("node_id", ""))
        sel = n.get("selections", 0)
        n_score = eta1 * u + eta2 * p + eta3 / (1.0 + sel)
        if n_score > best_score:
            best_score = n_score
            best_id = n.get("node_id", "")
    return best_id