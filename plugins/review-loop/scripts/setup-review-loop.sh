#!/usr/bin/env bash
set -euo pipefail

# Review Loop — Setup Script
# Creates per-instance state file and prepares the review loop lifecycle.
# All per-instance files live under reviews/review-loop-{ID}/

ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      cat << 'HELP'
Usage: /review-loop <task description>

Starts a review loop:
  1. Claude implements your task
  2. Codex performs an independent code review
  3. Claude addresses the feedback

Multiple review loops can run concurrently — each gets its own isolated directory.

Environment variables:
  REVIEW_LOOP_CODEX_FLAGS  Override codex flags (default: --dangerously-bypass-approvals-and-sandbox)

Example:
  /review-loop Add user authentication with JWT tokens and proper test coverage
HELP
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

PROMPT="${ARGS[*]:-}"

if [ -z "$PROMPT" ]; then
  echo "Error: No task description provided."
  echo "Usage: /review-loop <task description>"
  exit 1
fi

# Check dependencies
if ! command -v codex &> /dev/null; then
  echo "Warning: 'codex' CLI not found. The review phase will fall back to self-review."
  echo "Install Codex CLI to enable independent code reviews."
fi

if ! command -v jq &> /dev/null; then
  echo "Error: 'jq' is required but not found."
  echo "  macOS:  brew install jq"
  echo "  Linux:  apt install jq  /  yum install jq"
  echo "  Docs:   https://jqlang.github.io/jq/download/"
  exit 1
fi

# Generate unique ID: timestamp + random hex
# Prefer openssl, fallback to /dev/urandom
if command -v openssl &> /dev/null; then
  RAND_HEX=$(openssl rand -hex 3)
else
  RAND_HEX=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
REVIEW_ID="$(date +%Y%m%d-%H%M%S)-${RAND_HEX}"

LOOP_DIR="reviews/review-loop-${REVIEW_ID}"
TEMP_DIR="${LOOP_DIR}/temp"

# Create per-instance directories
mkdir -p "$TEMP_DIR"

# Write session breadcrumb (links this Claude session to the review ID)
mkdir -p .claude
echo "$REVIEW_ID" > ".claude/rl-session-${PPID}"

# Create state file in per-instance temp directory
cat > "${TEMP_DIR}/state.md" << STATE_EOF
---
active: true
phase: task
review_id: ${REVIEW_ID}
iteration: 1
max_iterations: 6
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

${PROMPT}
STATE_EOF

echo ""
echo "Review Loop activated"
echo "  ID:      ${REVIEW_ID}"
echo "  Dir:     ${LOOP_DIR}"
echo "  Phase:   1/2 — Task implementation"
echo ""
echo "  Lifecycle:"
echo "    1. You implement the task"
echo "    2. Stop hook runs Codex review loop (foreground)"
echo "    3. Ctrl+C to cancel at any time"
echo ""
