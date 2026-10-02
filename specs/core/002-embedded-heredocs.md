---
id: CORE-02
title: "Embedded heredocs: quoted, unique delimiters, deliberate escapes"
area: core
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/02-materialize-context.sh
  - tests/unit/10-entrypoint-content.sh
---

# CORE-02: Embedded heredocs: quoted, unique delimiters, deliberate escapes

## Rule

- Heredoc delimiters for embedded files MUST be single-quoted (`<<'NIXENV_…'`)
  so content is written verbatim.
- Each embedded file MUST use a unique delimiter; never reuse one. Nested
  heredocs inside (`<<EOF`, `<<RUN`) must not clash with the outer delimiter.
- In `entrypoint.sh`, `$PROFILE` is expanded by the entrypoint at container
  start while `\$HOME` stays literal so zsh expands it later — preserve the
  backslashes.

## Why

An unquoted delimiter expands variables on the HOST at materialise time; a
reused delimiter ends the outer heredoc early and silently truncates the file.

## How

The entrypoint writes `.zshenv` with `<<EOF` and the sshd `run` script with
`<<RUN`, inside the outer `NIXENV_ENTRYPOINT`. Check generated files with
`sh -n` after materialising.
