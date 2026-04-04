# review-loop Plugin — Agent Guidelines

## What this is

A Claude Code plugin that creates a continuous review loop (up to 6 rounds):
1. Claude implements a task and writes an implementation summary
2. Stop hook runs the orchestrator synchronously (foreground, same process group)
3. Orchestrator runs a single-reviewer Codex review
4. If VERDICT: FAIL, orchestrator launches a fresh `claude -p` session to address findings
5. Repeat until VERDICT: PASS or max iterations reached
6. All output appears in the user's terminal — heartbeat prints every 30s
7. Ctrl+C at any time cancels the entire review loop (SIGINT propagates to all children)

## Concurrency

Multiple review loops can run simultaneously. Each instance is fully isolated:
- All per-instance files live under `reviews/review-loop-{ID}/` (reviews, summaries, temp files, logs)
- Session breadcrumbs (`.claude/rl-session-{PID}`) link Claude sessions to review loop instances
- No shared state files, no mutexes needed

## Architecture

```
/review-loop "task"
  → Claude implements → writes summary → exits
  → Stop hook runs orchestrator SYNCHRONOUSLY (foreground)
  → Orchestrator loop:
      Codex review → parse verdict
      → PASS: done
      → FAIL + iterations left: claude -p addresses → loop
      → FAIL + max reached: done
  → Stop hook approves exit → Claude Code exits
  → Ctrl+C at any point → SIGINT → everything stops
```

## Cancellation

No `/cancel-review` command needed. The orchestrator runs in the foreground inside the stop hook:
- **Ctrl+C** sends SIGINT to the entire process group (Claude Code + stop hook + orchestrator + codex/claude children)
- Orchestrator traps SIGINT → kills child processes → cleans up state files → exits
- Stop hook traps SIGINT → approves exit
- Claude Code exits

## Phases

| Phase | Who | Meaning |
|-------|-----|---------|
| `task` | First Claude session | Implementing the task. If summary exists, hook runs orchestrator. If not, hook approves exit (user interrupted). |
| `orchestrated` | State during headless runs | Set by orchestrator while Claude -p runs. Hook approves exit without cleanup. |

## Per-Instance File Layout

```
reviews/review-loop-{ID}/
├── temp/
│   ├── state.md            # YAML frontmatter + task description
│   ├── status              # Current stage (read by heartbeat)
│   ├── claude-prompt.txt   # Transient, per-round prompt
│   └── loop.log            # Timestamped event log
├── summary-0.md            # Initial implementation summary
├── summary-N.md            # Round N addressing summary
├── review-1.md             # Round 1 Codex review
└── review-N.md             # Round N Codex review
```

Session breadcrumbs (tiny files linking Claude PIDs to review IDs):
```
.claude/rl-session-{PID}   # Contains just the review ID string
```

## Session Identification

The stop hook needs to know which review loop instance the exiting Claude session belongs to:

1. **Primary**: Session breadcrumb at `.claude/rl-session-{PPID}` — written during setup (for interactive sessions) and by orchestrator (for headless sessions)
2. **Fallback**: Scan `reviews/review-loop-*/temp/state.md` for active instances — works when only one instance is in `task` phase

For headless `orchestrated` sessions: orchestrator writes `.claude/rl-session-{CLAUDE_PID}` immediately after launching `claude -p`, so the stop hook can identify the instance.

## Heartbeat

The orchestrator runs a background heartbeat process that prints a status line every 30 seconds:
```
  ⏳ 02:30 │ Round 1/6 — Codex reviewing
```

This proves the process is alive. After each stage completes, a summary line is printed:
```
  ✓ Codex review done (3m42s, 2048 bytes)
```

## Single Reviewer

One Codex reviewer (no multi-agent). Prompt auto-detects project type and includes conditional sections:

| Condition | Extra focus area |
|-----------|-----------------|
| Expo/RN detected | Platform APIs, gestures, styling, native gotchas |
| `.web.tsx` + `.native.tsx` | Platform parity |
| HuisHype monorepo | Multi-country, no NL hardcoding |
| Browser UI dirs | Web UX, layout, console errors |

## Verdict Protocol

Codex review files MUST start with exactly:
- `VERDICT: PASS` — code looks good, loop terminates
- `VERDICT: FAIL` — findings listed by severity, loop continues

Unparseable verdicts are treated as FAIL.

## Conventions

- Shell scripts must work on both macOS and Linux (no `setsid`)
- Stop hook MUST always produce valid JSON to stdout
- Fail-open: on any error or signal, approve exit
- Review ID validated: `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$`
- Orchestrator outputs to `/dev/tty` (fallback: log file if no terminal)
- Headless Claude runs WITHOUT `--bare` — gets full CLAUDE.md, plugins, MCP, LSP context
- Stop hook handles `orchestrated` phase by approving without cleanup (prevents interference with orchestrator loop)
- Phase transitions use awk rewrite (not sed)
- All `jq` calls have `|| printf '...'` fallbacks
- Cleanup functions start with `set +e` to prevent ERR trap recursion
- No hook timeout — orchestrator runs as long as needed

## Testing

After modifying scripts, test these paths:
- No state file → hook approves
- `phase: task` + no summary → hook approves + cleans up (user interrupted)
- `phase: task` + summary exists → hook runs orchestrator synchronously
- Unknown phase → hook approves
- Malformed state → hook fails-open
- Ctrl+C during orchestrator → SIGINT kills everything cleanly
- Orchestrator: VERDICT: PASS → loop terminates round 1
- Orchestrator: VERDICT: FAIL → launches Claude, loops
- Orchestrator: max iterations → loop terminates
- Orchestrator: Codex failure → loop terminates with error
- Orchestrator: SIGTERM → graceful shutdown + cleanup
- Heartbeat prints every 30s during long-running stages
- **Concurrent**: Two instances in parallel → each uses own directory, no interference
- **Concurrent**: One finishes while other runs → cleanup only affects finished instance
- Session breadcrumb matches correctly for interactive and headless sessions
