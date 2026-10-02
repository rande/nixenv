---
id: RUN-12
title: "Claude: only the login is shared between projects"
area: runtime
security: SEC-03
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/28-claude-isolation.sh
  - tests/unit/10-entrypoint-content.sh
---

# RUN-12: Claude: only the login is shared between projects

## Rule

- Each project gets its own `$CLAUDE_DIR/profiles/<name>/{dot-claude/,claude.json}`
  (`prepare_claude_profile`, `claude_profile_dir`) mounted at
  `/home/app/.claude` and `/home/app/.claude.json`. Only
  `$CLAUDE_DIR/.credentials.json` is shared (rw: token refresh rewrites it).
- Mount targets are pre-created as FILES. A new profile is NOT seeded from the
  legacy shared `CLAUDE_JSON` — only `hasCompletedOnboarding`.
- `CLAUDE_CODE_PROJECT_DIR_NAME=nixenv-<project>` is set in BOTH `cmd_run` (`-e`,
  covers services and `shell`) and the entrypoint's `.zshenv` (ssh/zmx logins —
  sshd builds a fresh environment). It must equal the
  `$CLAUDE_DIR/projects/nixenv-<name>` mount.

## Why

Sharing `~/.claude` rw let one project plant hooks/MCP servers/CLAUDE.md that
ran in every other. Every project can still READ the shared token — documented,
not solved. Without the engine pre-creating files it makes directories.

## How

`delete` removes the profile and keeps transcripts.
