---
id: TOOL-07
title: "Optional GitHub token for flake inputs"
area: toolchain
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/33-github-token.sh
---

# TOOL-07: Optional GitHub token for flake inputs

## Rule

- `github_token` reads `$GITHUB_TOKEN`, then `$GITHUB_TOKEN_FILE`
  (`~/.nixenv/github_token`, mode 600). `nix_config` adds it as `access-tokens`
  only if `valid_github_token` passes (charset + `ghp_`/`github_pat_`… prefix;
  it lands in NIX_CONFIG, so no newlines).
- `ensure_github_token` runs at the start of base `build`/`update`: explains the
  limit, prints `GITHUB_TOKEN_URL` (fine-grained token page with NO permission
  params = public repos read-only), prompts once; Enter writes
  `$GITHUB_TOKEN_SKIP`. With no TTY it explains but never prompts and never
  writes the skip marker.
- Project builds never get the token (TOOL-04).

## Why

`github:` inputs resolve through api.github.com: 60 anonymous requests/hour per
IP, which a shared office/VPN address exhausts fast.

## How

`github-token [--clear|--status]` manages it. `run_builder base|project <cmd…>`
tees builder output and on failure explains "rate limit exceeded" or a 401 from
an expired token.
