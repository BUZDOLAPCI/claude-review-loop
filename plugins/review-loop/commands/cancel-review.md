---
description: "Cancel an active review loop (kills orchestrator if running)"
allowed-tools:
  - Bash
  - Read
---

Check if a review loop is active and read its state:

```bash
if [ -f .claude/review-loop.local.md ]; then echo "ACTIVE" && cat .claude/review-loop.local.md; else echo "NONE"; fi
```

If active, kill the orchestrator (if running) and clean up all state:

```bash
if [ -f .claude/review-loop-orchestrator.pid ]; then
  ORCH_PID=$(cat .claude/review-loop-orchestrator.pid)
  if [[ "$ORCH_PID" =~ ^[0-9]+$ ]] && kill -0 "$ORCH_PID" 2>/dev/null; then
    kill -- -"$ORCH_PID" 2>/dev/null || kill "$ORCH_PID" 2>/dev/null || true
    echo "Killed orchestrator (PID: $ORCH_PID)"
  else
    echo "Orchestrator not running (stale PID file)"
  fi
fi
rm -f .claude/review-loop.local.md .claude/review-loop.lock .claude/review-loop-orchestrator.pid .claude/review-loop-run-codex.sh .claude/review-loop-codex-prompt.txt .claude/review-loop-retries .claude/review-loop-claude-prompt.txt .claude/review-loop-summary.md
echo "Review loop cancelled and cleaned up."
```

Report: "Review loop cancelled (was at phase: X, round: Y/Z, review ID: W)"

If no review loop was active, report: "No active review loop found."
