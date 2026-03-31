#!/usr/bin/env bash
# Review Loop — Background Orchestrator
#
# Spawned by the stop hook after the first Claude session exits.
# Manages the continuous review loop: Codex reviews → Claude addresses → repeat.
#
# Usage: orchestrator.sh <REVIEW_ID> <MAX_ITERATIONS>
#   REVIEW_ID:      Format YYYYMMDD-HHMMSS-hexhex
#   MAX_ITERATIONS: Integer, typically 8
#
# Environment variables:
#   REVIEW_LOOP_CODEX_FLAGS  Override codex flags (default: --dangerously-bypass-approvals-and-sandbox)

set -euo pipefail

REVIEW_ID="${1:?Usage: orchestrator.sh <REVIEW_ID> <MAX_ITERATIONS>}"
MAX_ITERATIONS="${2:?Usage: orchestrator.sh <REVIEW_ID> <MAX_ITERATIONS>}"

LOG_FILE=".claude/review-loop.log"
STATE_FILE=".claude/review-loop.local.md"
SUMMARY_FILE=".claude/review-loop-summary.md"
PID_FILE=".claude/review-loop-orchestrator.pid"
PROMPT_FILE=".claude/review-loop-claude-prompt.txt"

CLAUDE_PID=""

# ── Logging ──────────────────────────────────────────────────────────────────

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [orchestrator] $*" >> "$LOG_FILE"
}

status_banner() {
  local msg="$1"
  local border
  border=$(printf '═%.0s' $(seq 1 ${#msg}))
  printf '\n╔═%s═╗\n║ %s ║\n╚═%s═╝\n\n' "$border" "$msg" "$border"
}

# ── State file helpers ───────────────────────────────────────────────────────

parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

update_field() {
  local field="$1"
  local value="$2"
  local TEMP_FILE="${STATE_FILE}.tmp.$$"

  awk -v f="$field" -v v="$value" '{
    if ($0 ~ "^" f ":") { print f ": " v }
    else { print }
  }' "$STATE_FILE" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$STATE_FILE"
}

get_task_description() {
  # Extract body after YAML frontmatter (everything after the closing ---)
  awk 'BEGIN{in_fm=0; past_fm=0} {
    if (past_fm) { print; next }
    if (/^---$/ && !in_fm) { in_fm=1; next }
    if (/^---$/ && in_fm) { past_fm=1; next }
  }' "$STATE_FILE" | sed '/./,$!d'
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
  set +e

  if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    log "Killing child Claude process (PID=$CLAUDE_PID)"
    kill "$CLAUDE_PID" 2>/dev/null
    wait "$CLAUDE_PID" 2>/dev/null
  fi

  rm -f "$STATE_FILE" "$PROMPT_FILE" "$PID_FILE"
  log "Orchestrator exiting (cleanup complete)"
}

# ── Traps ────────────────────────────────────────────────────────────────────

trap 'log "ERROR: orchestrator exited via ERR trap (line $LINENO)"; cleanup; exit 1' ERR
trap 'log "Received TERM/INT signal, shutting down"; cleanup; exit 0' TERM INT

# ── Project type detection ───────────────────────────────────────────────────

detect_expo_rn() {
  [ -f "app.json" ] && grep -q '"expo"' app.json 2>/dev/null && return 0
  [ -f "app.config.ts" ] || [ -f "app.config.js" ] && return 0
  for d in . apps/* packages/*; do
    [ -f "$d/app.config.ts" ] || [ -f "$d/app.config.js" ] && return 0
    [ -f "$d/app.json" ] && grep -q '"expo"' "$d/app.json" 2>/dev/null && return 0
    [ -f "$d/package.json" ] && grep -q '"react-native"' "$d/package.json" 2>/dev/null && return 0
  done
  return 1
}

detect_multi_platform() {
  find . -maxdepth 6 -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -name "*.web.tsx" 2>/dev/null | head -1 | grep -q . || return 1
  find . -maxdepth 6 -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -name "*.native.tsx" 2>/dev/null | head -1 | grep -q .
}

detect_huishype() {
  [ -d "agent-rules" ] && [ -f "packages/shared/src/config/country-config.ts" ]
}

detect_browser_ui() {
  [ -d "app" ] || [ -d "pages" ] || [ -d "src/app" ] || [ -d "src/pages" ] || \
    [ -d "public" ] || [ -f "index.html" ]
}

# ── Review prompt builder (single Codex reviewer) ───────────────────────────

build_review_prompt() {
  local REVIEW_FILE="$1"
  local TASK="$2"

  local IS_EXPO_RN=false
  local IS_MULTI_PLATFORM=false
  local IS_HUISHYPE=false
  local HAS_UI=false
  detect_expo_rn && IS_EXPO_RN=true
  detect_multi_platform && IS_MULTI_PLATFORM=true
  detect_huishype && IS_HUISHYPE=true
  detect_browser_ui && HAS_UI=true

  log "Project detection: expo_rn=$IS_EXPO_RN, multi_platform=$IS_MULTI_PLATFORM, huishype=$IS_HUISHYPE, browser_ui=$HAS_UI"

  cat << REVIEW_EOF
You are an independent code reviewer. Review the recent changes in this repository and write your findings to: ${REVIEW_FILE}

## Context

The current changes are done as a result of this request:
${TASK}

## What to review

Run \`git diff\` and \`git diff --cached\` to see all uncommitted changes. Also run \`git log --oneline -10\` and \`git diff HEAD~5\` for recently committed work.

Check the current changes and review them. Verify every change against the codebase.

Read project documentation: any AGENTS.md, CLAUDE.md files, and if an \`agent-rules/\` directory exists, read the specs there — changes should align with those design decisions.

## Focus areas

- **Correctness**: Does the code do what it claims? Any bugs, off-by-one errors, race conditions?
- **Completeness**: Check if the changes are complete, correct and finalized. Anything missing, half-implemented, or left as TODO?
- **Edge cases**: What happens with empty inputs, nulls, concurrent access, error paths?
- **Test coverage**: Are changes covered by tests? Any obvious gaps?
- **Architecture alignment**: Do changes fit the project structure and design decisions in docs?
- **Ideal & optimal**: We should always aim for ideal and optimal implementations. No workarounds or temporary fixes. Only root cause fixes and optimal solutions. Do the changes reflect that?
- **Improvements**: Any missing things? Anything that looks incorrect or incomplete? Any improvements?

Don't make any changes, just report back. Write the review to the file specified above.

Use subagents and tasks to keep main context lean. Orchestrate this work now.
REVIEW_EOF

  if [ "$IS_EXPO_RN" = "true" ]; then
    cat << 'EXPO_SECTION'

## React Native / Expo

This is an Expo + React Native project (New Architecture / Fabric + TurboModules). Also check:
- Platform-specific gotchas (iOS/Android differences, native module compatibility)
- Gesture handling, animation performance, and native view lifecycle
- Metro bundler / Expo Router platform resolution concerns
EXPO_SECTION
  fi

  if [ "$IS_MULTI_PLATFORM" = "true" ]; then
    cat << 'PLATFORM_SECTION'

## Multi-Platform Parity

This codebase has .web.tsx and .native.tsx platform files. Also check:
- Were changes made to one platform but not the other where they should match?
- Anything duplicated that should be shared, or shared that should stay split?
- Platform-specific behavior differences that could confuse users
PLATFORM_SECTION
  fi

  if [ "$IS_HUISHYPE" = "true" ]; then
    cat << 'HUISHYPE_SECTION'

## Multi-Country (HuisHype)

This is a multi-country app (19 European countries). Also check:
- Any hardcoded Dutch/NL assumptions or country-specific shortcuts?
- Places that should use shared country config, formatters, or country_code handling but don't?
- Anything that only works for the Netherlands?
HUISHYPE_SECTION
  fi

  if [ "$HAS_UI" = "true" ]; then
    cat << 'UI_SECTION'

## Web UX

This project has browser UI. Also check:
- Layout issues, responsive breakpoints, z-index stacking
- Console errors, missing error boundaries, loading states
- Accessibility concerns (keyboard nav, screen readers)
UI_SECTION
  fi

  cat << VERDICT_EOF

## Output format

Write your review to: ${REVIEW_FILE}

The **FIRST LINE** of the review file MUST be exactly one of:
\`\`\`
VERDICT: PASS
\`\`\`
or
\`\`\`
VERDICT: FAIL
\`\`\`

If **VERDICT: FAIL**, group findings by severity:

### Critical
(Issues that will cause bugs, data loss, or security vulnerabilities)

### High
(Issues that will likely cause problems or significantly degrade quality)

### Moderate
(Issues worth fixing but not urgent)

### Minor
(Nitpicks, style, minor improvements)

For each finding: file path, line number (if applicable), severity, description, and suggested fix.

If **VERDICT: PASS**, write a brief explanation of why the code looks good and any minor observations that don't warrant a FAIL.

Be thorough but fair. Don't nitpick style — focus on substance.
VERDICT_EOF
}

# ── Claude addressing prompt builder ─────────────────────────────────────────

build_claude_prompt() {
  local ROUND="$1"
  local MAX="$2"
  local REVIEW_FILE="$3"
  local TASK="$4"

  cat << CLAUDE_EOF
You are in round ${ROUND}/${MAX} of an automated review loop.

## Context

The current changes are done as a result of this request:
${TASK}

## What to do

1. Read \`.claude/review-loop-summary.md\` for context from previous rounds (if it exists)
2. Read the review file: \`${REVIEW_FILE}\` — it contains a review of the current changes
3. Analyze and verify the recommendations and their solutions against the codebase
4. For each finding in the review:
   - If you **agree** and the recommendation makes sense: implement the fix
   - If you **disagree**: briefly note why you're skipping it
5. Focus on **critical** and **high** severity items first
6. Run the quality gate: typecheck + tests (e.g., \`pnpm -C apps/app typecheck && pnpm -C apps/app test\` or the project's equivalent)
7. Update \`.claude/review-loop-summary.md\` — append a \`## Round ${ROUND}\` section documenting:
   - What you fixed
   - What you skipped and why
   - Quality gate results

Use your own judgment. Do not blindly implement every suggestion — verify recommendations against the codebase before acting on them.

Use tasks and subagents to keep main context lean. Orchestrate this work now.
CLAUDE_EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "Orchestrator started (review_id=$REVIEW_ID, max_iterations=$MAX_ITERATIONS)"

# Extract task description from state file
TASK=$(get_task_description)
if [ -z "$TASK" ]; then
  log "WARNING: no task description found in state file"
  TASK="(no task description available)"
fi

# Codex flags
CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"

# Write PID file
mkdir -p "$(dirname "$PID_FILE")"
echo $$ > "$PID_FILE"

# Validate codex is on PATH
if ! command -v codex &>/dev/null; then
  log "ERROR: codex not found on PATH — cannot run review loop"
  cleanup
  exit 1
fi

# Read starting iteration from state file (default 1)
ITERATION=$(parse_field "iteration")
ITERATION="${ITERATION:-1}"

mkdir -p reviews

while [ "$ITERATION" -le "$MAX_ITERATIONS" ]; do
  REVIEW_FILE="reviews/review-${REVIEW_ID}-round-${ITERATION}.md"

  # ── Codex Review ──────────────────────────────────────────────────────────

  status_banner "Round ${ITERATION}/${MAX_ITERATIONS} -- Codex Review"
  log "Round ${ITERATION}/${MAX_ITERATIONS}: starting Codex review"

  REVIEW_PROMPT=$(build_review_prompt "$REVIEW_FILE" "$TASK")
  START_TIME=$(date +%s)

  # Run Codex single-reviewer
  # shellcheck disable=SC2086
  if ! codex $CODEX_FLAGS exec "$REVIEW_PROMPT"; then
    log "ERROR: codex exited with non-zero status in round $ITERATION"
    cleanup
    exit 1
  fi

  ELAPSED=$(( $(date +%s) - START_TIME ))
  log "Codex review completed in ${ELAPSED}s"

  # Verify review file was created
  if [ ! -f "$REVIEW_FILE" ]; then
    log "ERROR: codex did not create review file ($REVIEW_FILE) in round $ITERATION"
    cleanup
    exit 1
  fi

  log "Review file created: $REVIEW_FILE ($(wc -c < "$REVIEW_FILE") bytes)"

  # ── Parse Verdict ─────────────────────────────────────────────────────────

  VERDICT_LINE=$(head -1 "$REVIEW_FILE")
  VERDICT=""
  case "$VERDICT_LINE" in
    "VERDICT: PASS") VERDICT="PASS" ;;
    "VERDICT: FAIL") VERDICT="FAIL" ;;
    *)
      log "WARNING: could not parse verdict from first line: '$VERDICT_LINE' — treating as FAIL"
      VERDICT="FAIL"
      ;;
  esac

  log "Round ${ITERATION} verdict: $VERDICT"

  # ── PASS → done ───────────────────────────────────────────────────────────

  if [ "$VERDICT" = "PASS" ]; then
    status_banner "PASS -- Review loop complete (round ${ITERATION}/${MAX_ITERATIONS})"
    log "Review loop completed with PASS in round $ITERATION"
    cleanup
    exit 0
  fi

  # ── Max iterations reached → done ─────────────────────────────────────────

  if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
    status_banner "Max iterations reached (${MAX_ITERATIONS}) -- Review loop ending"
    log "Review loop ended: max iterations reached ($MAX_ITERATIONS) with verdict FAIL"
    cleanup
    exit 0
  fi

  # ── FAIL → launch Claude to address findings ─────────────────────────────

  NEXT_ITERATION=$(( ITERATION + 1 ))
  update_field "iteration" "$NEXT_ITERATION"
  update_field "phase" "orchestrated"

  status_banner "Round ${ITERATION}/${MAX_ITERATIONS} -- Claude Addressing Findings"
  log "Launching Claude to address findings from round $ITERATION"

  CLAUDE_PROMPT=$(build_claude_prompt "$NEXT_ITERATION" "$MAX_ITERATIONS" "$REVIEW_FILE" "$TASK")
  printf '%s' "$CLAUDE_PROMPT" > "$PROMPT_FILE"

  # Launch headless Claude session (no --bare: gets full CLAUDE.md, plugins, MCP, LSP context)
  claude -p --dangerously-skip-permissions < "$PROMPT_FILE" &
  CLAUDE_PID=$!
  log "Claude launched (PID=$CLAUDE_PID) for round $NEXT_ITERATION"

  # Wait for Claude to finish (non-zero exit is a warning, not a fatal error)
  if ! wait "$CLAUDE_PID"; then
    log "WARNING: Claude exited with non-zero status (PID=$CLAUDE_PID) in round $ITERATION"
  fi
  CLAUDE_PID=""

  # Clean up prompt file
  rm -f "$PROMPT_FILE"

  # Advance to next iteration
  ITERATION=$NEXT_ITERATION
done

# Should not reach here, but just in case
log "Orchestrator loop exited unexpectedly"
cleanup
exit 0
