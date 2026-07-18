# cerebro-tests

Plain-bash test runner for cerebro's read-only bridge subcommands
(`cerebro git`, `cerebro gh`, `cerebro read`, `cerebro grep`,
`cerebro ls`). No external test framework.

```bash
bash bin/cerebro-tests/run.sh
```

Each test prints `PASS` / `FAIL` (or `SKIP` when `rg` is missing). The
runner exits non-zero if any assertion fails. The sandbox lives in
`$(mktemp -d)` and is cleaned up on exit.

The `gh` validation tests do not require `gh` to be installed -- they
exercise validation paths that fire before any real `gh` invocation.

The interactive-guard tests (190-197) drive `cerebro` under an allocated
pseudo-terminal via `pty_run.py`, the way a controller such as Codex
(launched with `tty: true`) drives it: a genuine PTY with a non-shell
parent is accepted, pipes/redirects/no-TTY are rejected, and a full
interactive session can receive a prompt, continue, and end on EOF or
Ctrl-C through the PTY. They use only the python3 `pty`/`termios` stdlib
modules plus a stub `opencode`, so no real backend is launched.
