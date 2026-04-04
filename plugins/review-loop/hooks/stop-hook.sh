#!/usr/bin/env bash
# Review Loop — Stop Hook (concurrent-safe)
#
# Uses per-instance state files under reviews/review-loop-{ID}/temp/
# Session breadcrumbs in .claude/rl-session-{PID} link sessions to instances.
#
# When the implementation summary exists, runs the orchestrator SYNCHRONOUSLY
# (foreground, same process group). Ctrl+C propagates SIGINT to everything.
#
# On any error or signal, default to allowing exit (never trap the user).

trap 'printf "{\"decision\":\"approve\"}\n"; exit 0' ERR INT TERM

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

# ── Resolve which review loop instance this session belongs to ───────────────

REVIEW_ID=""

# Method 1: session breadcrumb by PPID (fast, works for concurrent instances)
BREADCRUMB=".claude/rl-session-${PPID}"
if [ -f "$BREADCRUMB" ]; then
  REVIEW_ID=$(cat "$BREADCRUMB")
fi

# Method 2: scan for active instances (fallback when PPID breadcrumb is missing)
if [ -z "$REVIEW_ID" ]; then
  TASK_COUNT=0
  LAST_TASK_RID=""
  HAS_ORCHESTRATED=false

  for sf in reviews/review-loop-*/temp/state.md; do
    [ -f "$sf" ] || continue
    a=$(sed -n 's/^active: *//p' "$sf" | head -1)
    p=$(sed -n 's/^phase: *//p' "$sf" | head -1)
    if [ "$a" = "true" ]; then
      if [ "$p" = "task" ]; then
        LAST_TASK_RID=$(sed -n 's/^review_id: *//p' "$sf" | head -1)
        TASK_COUNT=$((TASK_COUNT + 1))
      elif [ "$p" = "orchestrated" ]; then
        HAS_ORCHESTRATED=true
      fi
    fi
  done

  if [ "$TASK_COUNT" -eq 1 ]; then
    # Exactly one active task-phase instance — use it
    REVIEW_ID="$LAST_TASK_RID"
  elif [ "$TASK_COUNT" -eq 0 ] && [ "$HAS_ORCHESTRATED" = "true" ]; then
    # Only orchestrated instances running — headless session exiting
    printf '{"decision":"approve"}\n'
    exit 0
  elif [ "$TASK_COUNT" -gt 1 ]; then
    # Multiple task instances, can't determine which — approve safely
    printf '{"decision":"approve"}\n'
    exit 0
  fi
fi

# No active instance found → not a review loop session
if [ -z "$REVIEW_ID" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Validate review_id format to prevent path traversal
if ! echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# ── Per-instance paths ───────────────────────────────────────────────────────

LOOP_DIR="reviews/review-loop-${REVIEW_ID}"
TEMP_DIR="${LOOP_DIR}/temp"
STATE_FILE="${TEMP_DIR}/state.md"
LOG_FILE="${TEMP_DIR}/loop.log"

if [ ! -f "$STATE_FILE" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [stop-hook] $*" >> "$LOG_FILE" 2>/dev/null || true
}

parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
MAX_ITERATIONS=$(parse_field "max_iterations")
MAX_ITERATIONS="${MAX_ITERATIONS:-6}"

# Not active → allow exit
if [ "$ACTIVE" != "true" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

case "$PHASE" in
  task)
    SUMMARY_FILE="${LOOP_DIR}/summary-0.md"
    if [ -f "$SUMMARY_FILE" ]; then
      # Summary exists — run orchestrator synchronously (foreground)
      # Ctrl+C sends SIGINT to the entire process group, killing everything.
      PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
      ORCHESTRATOR="${PLUGIN_ROOT}/hooks/orchestrator.sh"

      if [ ! -x "$ORCHESTRATOR" ]; then
        log "ERROR: orchestrator not found or not executable: $ORCHESTRATOR"
        printf '{"decision":"approve"}\n'
        exit 0
      fi

      log "Summary found, running orchestrator synchronously (review_id=$REVIEW_ID, max_iterations=$MAX_ITERATIONS)"

      # Run synchronously — output to /dev/tty (stdout is piped to Claude Code)
      # || true: if orchestrator exits non-zero (SIGINT, error), still approve exit
      if [ -e /dev/tty ]; then
        "$ORCHESTRATOR" "$REVIEW_ID" "$MAX_ITERATIONS" </dev/null >/dev/tty 2>&1 || true
      else
        "$ORCHESTRATOR" "$REVIEW_ID" "$MAX_ITERATIONS" </dev/null >>"$LOG_FILE" 2>&1 || true
      fi

      printf '{"decision":"approve"}\n'
    else
      # No summary — user likely interrupted (Ctrl+C). Clean up and allow exit.
      log "No summary found, cleaning up (review_id=$REVIEW_ID)"
      rm -f "$STATE_FILE"
      rm -f ".claude/rl-session-${PPID}"
      printf '{"decision":"approve"}\n'
    fi
    ;;

  orchestrated)
    # Headless Claude session exiting during orchestrator loop — approve without cleanup.
    # The orchestrator manages the state file lifecycle.
    log "Orchestrated session exiting, approving"
    printf '{"decision":"approve"}\n'
    ;;

  *)
    # Unknown phase — allow exit
    log "WARN: unknown phase '$PHASE'"
    printf '{"decision":"approve"}\n'
    ;;
esac
