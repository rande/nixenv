---
name: commit
description: Commit the working tree's changes as one or more focused commits, each with a `type(part): summary` subject and a body. Splits unrelated changes (including hunks of the same file) into separate commits. Use ONLY when the user asks to commit (e.g. "/commit", "commit this", "commit the changes"); never on your own initiative.
allowed-tools: Read, Grep, Glob, Bash
---

# Commit the changes, one logical change per commit

The user asked you to commit. That request is the authorization: plan the
commits, make them, then report. Do not push, tag, amend or rebase existing
commits unless the user says so.

## 1. Survey

```sh
git status --porcelain=v1 -uall
git diff --cached --stat ; git diff --stat
git log --format='%h %s' -15          # style of recent subjects
```

- Read the actual diffs (`git diff --cached`, `git diff`, and every untracked
  file) before grouping. Never commit content you have not read.
- Staged and unstaged changes are both in scope: the user often stages part of
  the work and leaves later edits unstaged on top. Group by MEANING, not by
  whether it was staged.
- If the user named a subset ("commit the windmill fix"), commit only that and
  leave everything else exactly as it was (staged stays staged).

## 2. Never commit

- `~/.nixenv/projects/` content, keys, tokens, `.git-credentials`, `.env` with
  values, anything matching `ghp_`/`github_pat_` (CORE-08, TOOL-07).
- Scratch output, logs, `result` symlinks, editor/OS files.
- `packaging/homebrew/*` version bumps and `NIXENV_VERSION` / `docs/index.html`
  `rev` bumps: `release.sh` owns those commits (REL-04).

If one of these is present, leave it out and say so in the report.

## 3. Group into commits

One commit = one change a reviewer could accept or revert on its own. Keep
together what belongs together in this repo:

- A behaviour change, the spec it alters (`specs/**`, plus the index lines in
  `specs/README.md` and `.claude/rules/<area>.md` for a new spec) and its
  tests go in the SAME commit (AGENTS.md: "update that spec in the same
  commit"). Test 39 fails on a spec that is not indexed.
- `templates/flake.nix` and the `NIXENV_MODEL_FLAKE` heredoc in `nixenv.sh`
  change together (TPL-14).
- A generated `flake.lock` goes with the flake or script that pins it.
- README/RELEASING/AGENTS edits go with the feature they document; standalone
  doc work is its own `docs` commit.

Split when the changes are independent: a bug fix found along the way, an
unrelated refactor, a new skill, a lock refresh. Don't split so finely that a
commit breaks the suite or leaves a spec describing code that isn't there yet.
When in doubt, fewer commits.

Order commits so each one builds on the previous (helpers before their users,
fixes before features that rely on them).

## 4. Message format

```
type(part): summary

Body: what changed and WHY, wrapped at ~72 columns. Name the spec ids
touched (e.g. TOOL-02, RUN-07) and the incident or bug when there is one.
Bullets are fine for several related points.

Co-Authored-By: <the attribution line from the current system reminder>
```

- `type`: `feat` (new behaviour), `fix` (bug), `refactor` (no behaviour
  change), `perf`, `test` (tests only), `docs` (docs/specs only), `chore`
  (tooling, skills, locks, housekeeping), `build`, `ci`, `revert`.
- `part`: the area touched, lowercase, short. Prefer the spec areas: `core`,
  `toolchain`, `runtime`, `ssh`, `networking`, `egress`, `capture`, `deploy`,
  `export`, `templates`, `release`, `dev`, `testing`; or a narrower name when
  it reads better (`windmill`, `proxy`, `entrypoint`, `nix`, `skills`).
- `summary`: imperative, lowercase start, no trailing period, ≤ 72 chars for
  the whole subject line.
- Always a body, even a short one. Always the blank line after the subject.
- End with the attribution trailer the system reminder gives for commits; if
  none is given, add none.

## 5. Verify, then commit

1. Run `./tests/run.sh` once on the full working tree (TEST-01). If it fails,
   STOP: report the failure and commit nothing.
2. Reset the index to a clean slate only if you will restage everything
   yourself: `git reset -q` (keeps the working tree). Note what was staged
   first so a partial request can restore it.
3. For each planned commit:
   - Whole files: `git add -- <paths>` (`git add -A -- <path>` for deletions).
   - Part of a file (hunks belonging to different commits): write the hunks
     for THIS commit to a patch in the scratchpad and stage it with
     `git apply --cached --recount <patch>`. Build it from
     `git diff -- <file>`, deleting the hunks that belong elsewhere.
     Interactive `git add -p` is not available.
   - Check what is staged: `git diff --cached --stat` and, for split files,
     `git diff --cached -- <file>`.
   - Commit with a heredoc so the message keeps its newlines:
     ```sh
     git commit -q -F - <<'MSG'
     type(part): summary

     Body…

     Co-Authored-By: …
     MSG
     ```
4. Afterwards `git status --porcelain` must show only what you deliberately
   left out. If an intermediate commit is in doubt (a split file, an
   ordering dependency), test it in a throwaway worktree without touching
   the user's tree:
   ```sh
   wt="$SCRATCH/wt"; git worktree add -q --detach "$wt" <sha>
   (cd "$wt" && ./tests/run.sh); git worktree remove --force "$wt"
   ```
   A failing intermediate commit means the grouping is wrong: say so and
   offer to regroup (that rewrites the new commits, so ask first).

If a hook rejects a commit, fix the cause and make a NEW commit attempt; never
`--no-verify`, never `--amend` a commit you didn't just create.

## 6. Report

List the commits (`git log --format='%h %s' <first>^..HEAD`), one line each
on what went where, anything left uncommitted and why, and the suite result.
Don't push.
