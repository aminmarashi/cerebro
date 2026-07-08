# Improvement-graph CLI: `improve_graph.py <file> <op> [args...]`. Ops:
#   add-node <file> <parent> <type> <ts> <overlay_hash> <meta_hash>
#            <findings_count> <accepted_count> <verdict> <utility_before>
#         -- append a node; print its node_id
#   update-utility <file> <utility>
#         -- set utility_after on the last node, compute delta_u
#   last-node <file>  -- print the last node_id (empty if none)
#   last-meta <file>  -- print the last meta-loop node_id (empty if none)
#   fast-since-meta <file> -- count fast-loop nodes since the last meta node
#   list <file>       -- TSV of all nodes
#   best-frontier <file> <eta1> <eta2> <eta3> -- best frontier node_id
import os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from improve_graph_lib import (
    add_node, update_utility, increment_selections, last_node_id,
    last_meta_node_id, fast_count_since_last_meta, list_nodes, best_frontier,
)

f = sys.argv[1]
op = sys.argv[2]

if op == "add-node":
    nid = add_node(f, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6],
                   sys.argv[7], sys.argv[8], sys.argv[9], sys.argv[10],
                   sys.argv[11] if len(sys.argv) > 11 else "")
    sys.stdout.write(nid + "\n")
elif op == "update-utility":
    update_utility(f, sys.argv[3] if len(sys.argv) > 3 else "")
elif op == "last-node":
    sys.stdout.write(last_node_id(f) + "\n")
elif op == "last-meta":
    sys.stdout.write(last_meta_node_id(f) + "\n")
elif op == "fast-since-meta":
    sys.stdout.write(str(fast_count_since_last_meta(f)) + "\n")
elif op == "list":
    list_nodes(f)
elif op == "best-frontier":
    eta1 = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    eta2 = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5
    eta3 = float(sys.argv[5]) if len(sys.argv) > 5 else 0.25
    sys.stdout.write(best_frontier(f, eta1, eta2, eta3) + "\n")
elif op == "increment-selections":
    increment_selections(f, sys.argv[3] if len(sys.argv) > 3 else "")
else:
    sys.exit(2)