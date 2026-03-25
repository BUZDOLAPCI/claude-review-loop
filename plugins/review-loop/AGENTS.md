# review-loop Plugin — Agent Guidelines

## What this is

A Claude Code plugin that creates a continuous review loop (up to 8 rounds):
1. Claude implements a task and writes an implementation summary
2. Stop hook spawns a background orchestrator and allows Claude to exit
3. Orchestrator runs a single-reviewer Codex review
4. If VERDICT: FAIL, orchestrator launches a fresh `claude -p --bare` session to address findings
5. Repeat until VERDICT: PASS or max iterations reached
6. All output appears in the user's original terminal

## Architecture

```
/review-loop "task"
  → Claude implements → writes summary → exits
  → Stop hook spawns orchestrator (background, same terminal)
  → Orchestrator loop:
      Codex review → parse verdict
      → PASS: done
      → FAIL + iterations left: claude -p --bare addresses → loop
      → FAIL + max reached: done
```

## Phases

| Phase | Who | Meaning |
|-------|-----|---------|
| `task` | First Claude session | Implementing the task. Hook blocks until summary is written, then spawns orchestrator. |
| `orchestrated` | State during headless runs | Set by orchestrator while Claude -p runs. Hook never fires (--bare skips hooks). |

## State File

`.claude/review-loop.local.md` — YAML frontmatter + task description body:

```yaml
---
active: true
phase: task | orchestrated
review_id: YYYYMMDD-HHMMSS-hexhex
iteration: 1
max_iterations: 8
started_at: ISO8601
---

Task description here
```

## Files

| File | Purpose | Lifecycle |
|------|---------|-----------|
| `.claude/review-loop.local.md` | State file | Created by command, cleaned up by orchestrator or cancel |
| `.claude/review-loop-summary.md` | Implementation summary | Written by Claude, read by orchestrator for context |
| `.claude/review-loop-orchestrator.pid` | Orchestrator PID | Written by orchestrator, read by cancel |
| `.claude/review-loop-claude-prompt.txt` | Prompt for headless Claude | Transient, per-round |
| `.claude/review-loop.log` | Timestamped event log | Persistent |
| `reviews/review-{id}-round-{N}.md` | Codex review per round | Persistent |

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

- Shell scripts must work on both macOS and Linux (no `setsid`, use subshell + `disown`)
- Stop hook MUST always produce valid JSON to stdout
- Fail-open: on any error, approve exit
- Review ID validated: `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$`
- Orchestrator outputs to `/dev/tty` (fallback: log file if no terminal)
- Headless Claude uses `--bare` flag (skips hooks, plugins, CLAUDE.md auto-discovery)
- Phase transitions use awk rewrite (not sed)
- All `jq` calls have `|| printf '...'` fallbacks
- Cleanup functions start with `set +e` to prevent ERR trap recursion

## Testing

After modifying scripts, test these paths:
- No state file → hook approves
- `phase: task` + no summary → hook blocks
- `phase: task` + summary exists → hook spawns orchestrator + approves
- Unknown phase → hook cleans up + approves
- Malformed state → hook fails-open
- `/cancel-review` with running orchestrator → kills process + cleans up
- `/cancel-review` with no loop → reports "not found"
- Orchestrator: VERDICT: PASS → loop terminates round 1
- Orchestrator: VERDICT: FAIL → launches Claude, loops
- Orchestrator: max iterations → loop terminates
- Orchestrator: Codex failure → loop terminates with error
- Orchestrator: SIGTERM → graceful shutdown + cleanup
