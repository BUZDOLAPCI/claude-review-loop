# review-loop

A Claude Code plugin that adds an automated, continuous code review loop to your workflow.

## What it does

When you use `/review-loop`, the plugin creates a continuous review cycle (up to 8 rounds):

1. **Implement**: Claude implements your task, writes an implementation summary, then exits
2. **Review**: A background orchestrator runs an independent [Codex](https://github.com/openai/codex) review
3. **Address**: If the review finds issues, a fresh Claude session addresses them
4. **Repeat**: Back to step 2, until the review passes or max rounds are reached

Everything runs in the same terminal — you can watch the entire loop unfold.

## Review coverage

A single Codex reviewer analyzes the changes. The prompt auto-detects project type and adds relevant focus areas:

| Focus | Condition |
|-------|-----------|
| **Code correctness** | Always — bugs, edge cases, test gaps, workarounds |
| **Architecture alignment** | Always — project structure, spec drift, regressions |
| **React Native / Expo** | If Expo config or `react-native` detected |
| **Platform parity** | If both `.web.tsx` and `.native.tsx` files exist |
| **Multi-country** | If HuisHype-style country config detected |
| **Web UX** | If browser UI directories exist |

Each review ends with a verdict: `VERDICT: PASS` (loop ends) or `VERDICT: FAIL` (loop continues).

## Requirements

- [Claude Code](https://claude.ai/code) (CLI)
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- [Codex CLI](https://github.com/openai/codex) — `npm install -g @openai/codex`

## Installation

From the CLI:

```bash
claude plugin marketplace add BUZDOLAPCI/claude-review-loop
claude plugin install review-loop@caslan-review
```

Or from within a Claude Code session:

```
/plugin marketplace add BUZDOLAPCI/claude-review-loop
/plugin install review-loop@caslan-review
```

## Updating

```bash
claude plugin marketplace update caslan-review
claude plugin update review-loop@caslan-review
```

## Usage

### Start a review loop

```
/review-loop Add user authentication with JWT tokens and test coverage
```

Claude implements the task. When it finishes:
1. Stop hook blocks exit until Claude writes an implementation summary
2. Claude writes the summary and exits
3. Background orchestrator takes over the terminal
4. Codex reviews the changes → `VERDICT: PASS` or `VERDICT: FAIL`
5. If FAIL: fresh `claude -p --bare` session addresses findings
6. Repeat until PASS or 8 rounds

### Cancel a review loop

```
/cancel-review
```

Kills the orchestrator (and any running Claude session) and cleans up all state files.

## How it works

The plugin uses a **Stop hook** to intercept Claude's exit, and a **background orchestrator** for the review loop:

1. **Stop hook** reads `.claude/review-loop.local.md` — if summary exists, spawns orchestrator and approves exit
2. **Orchestrator** runs Codex, parses verdict, launches fresh Claude sessions as needed
3. Headless Claude sessions use `--bare` (skips hooks/plugins) so the stop hook doesn't interfere

State is tracked in `.claude/review-loop.local.md`. Reviews are written to `reviews/review-<id>-round-<n>.md`.

## File structure

```
plugins/review-loop/
├── hooks/
│   ├── hooks.json            # Stop hook registration (30s timeout)
│   ├── stop-hook.sh          # Intercepts exit, spawns orchestrator
│   └── orchestrator.sh       # Background loop: Codex → Claude → repeat
├── commands/
│   ├── review-loop.md        # /review-loop slash command
│   └── cancel-review.md      # /cancel-review slash command
├── AGENTS.md                 # Agent operating guidelines
├── CLAUDE.md                 # Symlink to AGENTS.md
└── README.md
```

## Configuration

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex exec`. |

### Telemetry

Execution logs are written to `.claude/review-loop.log` with timestamps and event details.

## Credits

Inspired by the [Ralph Wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) and [Ryan Carson's compound engineering loop](https://x.com/ryancarson/article/2016520542723924279).
