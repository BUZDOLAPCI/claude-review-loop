---
description: "Start a review loop: implement task, get independent Codex review, address feedback (up to 8 rounds)"
argument-hint: "<task description>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

First, set up the review loop by running this setup command:

```bash
set -e && REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')" && LOOP_DIR="reviews/review-loop-${REVIEW_ID}" && mkdir -p .claude "$LOOP_DIR" && if [ -f .claude/review-loop.local.md ]; then echo "Error: A review loop is already active. Use /cancel-review first." && exit 1; fi && command -v codex >/dev/null 2>&1 || { echo "Error: Codex CLI is not installed. Install it: npm install -g @openai/codex"; exit 1; } && command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install it: apt install jq"; exit 1; } && rm -f .claude/review-loop.lock .claude/review-loop-orchestrator.pid && cat > .claude/review-loop.local.md << STATE_EOF
---
active: true
phase: task
review_id: ${REVIEW_ID}
iteration: 1
max_iterations: 8
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

$ARGUMENTS
STATE_EOF
echo "Review Loop activated (ID: ${REVIEW_ID}, loop dir: ${LOOP_DIR}, max rounds: 8)"
```

After setup completes successfully, proceed to implement the task described in the arguments. Work thoroughly and completely — write clean, well-structured, well-tested code.

When you believe the task is fully done:
1. Run the quality gate (typecheck + tests) and fix any failures
2. Write an implementation summary to the review loop directory (printed in setup output above) as `summary-0.md` — that includes:
   - What you implemented (files created/modified)
   - Key decisions and trade-offs
   - Current test status
3. Then stop

The stop hook will spawn a background orchestrator that:
- Runs an independent Codex review of your changes
- If findings exist, launches a fresh Claude session to address them
- Repeats up to 8 rounds until the review passes or max rounds are reached

All review output appears in this same terminal.

RULES:
- Complete the task to the best of your ability before stopping
- Do not stop prematurely or skip parts of the task
- Always write the summary file before stopping — the hook will block you if you forget
