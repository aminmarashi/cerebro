"""CLI for the chronological ``cerebro improve`` history."""

import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from improve_history_lib import (  # noqa: E402
    add_run,
    fast_count_since_last_meta,
    last_timestamp,
    list_runs,
)


path = sys.argv[1]
operation = sys.argv[2]

if operation == "add-run":
    run_id = add_run(
        path,
        sys.argv[3],
        sys.argv[4],
        sys.argv[5],
        sys.argv[6],
        sys.argv[7] if len(sys.argv) > 7 else "",
    )
    print(run_id)
elif operation == "last-timestamp":
    print(last_timestamp(path))
elif operation == "fast-since-meta":
    print(fast_count_since_last_meta(path))
elif operation == "list":
    list_runs(path)
else:
    sys.exit(2)
