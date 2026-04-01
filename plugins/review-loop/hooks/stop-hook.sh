#!/usr/bin/env bash
# Review Loop — Stop Hook (simplified)
#
# Lifecycle:
#   task phase: Claude finishes work → if summary exists, spawn orchestrator
#               and approve exit; otherwise block and ask for summary.
#
# On any error, default to allowing exit (never trap the user in a broken loop).

LOG_FILE=".claude/review-loop.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; rm -f .claude/review-loop.lock; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

STATE_FILE=".claude/review-loop.local.md"

# No active loop → allow exit
if [ ! -f "$STATE_FILE" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Parse a field from the YAML frontmatter
parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
REVIEW_ID=$(parse_field "review_id")
MAX_ITERATIONS=$(parse_field "max_iterations")
MAX_ITERATIONS="${MAX_ITERATIONS:-8}"

# Not active → clean up and exit
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Validate review_id format to prevent path traversal
if ! echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid review_id format: $REVIEW_ID"
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

case "$PHASE" in
  task)
    LOOP_DIR="reviews/review-loop-${REVIEW_ID}"
    SUMMARY_FILE="${LOOP_DIR}/summary-0.md"
    if [ -f "$SUMMARY_FILE" ]; then
      # Summary exists — spawn orchestrator detached and approve exit
      PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
      ORCHESTRATOR="${PLUGIN_ROOT}/hooks/orchestrator.sh"

      if [ ! -x "$ORCHESTRATOR" ]; then
        log "ERROR: orchestrator not found or not executable: $ORCHESTRATOR"
        rm -f "$STATE_FILE"
        printf '{"decision":"approve"}\n'
        exit 0
      fi

      # Spawn orchestrator detached — macOS compatible (no setsid)
      # /dev/tty sends output to user's terminal (not hook's piped stdout)
      if [ -e /dev/tty ]; then
        ( sleep 3 && exec "$ORCHESTRATOR" "$REVIEW_ID" "$MAX_ITERATIONS" ) </dev/null >/dev/tty 2>&1 &
        disown $!
      else
        ( sleep 3 && exec "$ORCHESTRATOR" "$REVIEW_ID" "$MAX_ITERATIONS" ) </dev/null >>"$LOG_FILE" 2>&1 &
        disown $!
      fi

      log "Summary found, spawning orchestrator (review_id=$REVIEW_ID, max_iterations=$MAX_ITERATIONS)"
      printf '{"decision":"approve"}\n'
    else
      # No summary yet — block and tell Claude to write one
      REASON="Before exiting, write an implementation summary to ${SUMMARY_FILE}

Include:
- Files changed (with brief description of each change)
- Key design decisions made
- Test status (what was run, what passed/failed)
- Any known issues or follow-ups

This summary is used by the review loop to understand what was done."

      SYS_MSG="Review Loop [${REVIEW_ID}] — Write implementation summary before exiting"

      jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
        '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
        || printf '{"decision":"block","reason":"Write implementation summary to %s before exiting.","systemMessage":"%s"}\n' "$SUMMARY_FILE" "$SYS_MSG"
    fi
    ;;

  orchestrated)
    # Headless Claude session exiting during orchestrator loop — approve without cleanup.
    # The orchestrator manages the state file lifecycle.
    log "Orchestrated session exiting, approving"
    printf '{"decision":"approve"}\n'
    ;;

  *)
    # Unknown phase — clean up and allow exit
    log "WARN: unknown phase '$PHASE', cleaning up"
    rm -f "$STATE_FILE" .claude/review-loop.lock
    printf '{"decision":"approve"}\n'
    ;;
esac
