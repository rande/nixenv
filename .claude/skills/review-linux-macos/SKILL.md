---
name: review-linux-macos
description: Portability review of nixenv shell code across macOS (Bash 3.2, BSD tools, Docker Desktop) and Linux (GNU tools, rootful/rootless Docker and Podman), plus the POSIX sh entrypoint that runs inside debian-slim. Use when reviewing any change to nixenv.sh, the embedded entrypoint, tests, release.sh or dev/ scripts, or when something works on one OS and not the other.
allowed-tools: Read, Grep, Glob, Bash
---

# Linux / macOS portability review for nixenv

nixenv runs in three shells with different rules — know which one each line
runs in before judging it:

| Code | Runs in | Rules |
|---|---|---|
| `nixenv.sh`, `release.sh`, `dev/*.sh`, `tests/*` | **Bash 3.2** on macOS (the formula has no `bash` dependency on purpose), Bash 5 on Linux | Bash 3.2 subset, BSD *and* GNU tools |
| embedded `entrypoint.sh`, sv `run` scripts, hooks | `/bin/sh` = **dash** in debian-slim | POSIX sh only |
| helper containers (`"$RUNTIME_IMAGE"` without the store) | debian-slim | coreutils/sed/grep/tar only — **no git, zsh, socat** |

## Bash 3.2 (macOS) — reject

`declare -A`, `mapfile`/`readarray`, `${v,,}`/`${v^^}`, `declare -n`, `&>>`,
`|&`, `wait -n`, `${a[-1]}`, `printf -v` with arrays, `[[ -v ]]`, `coproc`.
Under `set -u`, `"${arr[@]}"` on an **empty** array is an error in 3.2 — must be
`${arr[@]+"${arr[@]}"}`.

## `set -euo pipefail` traps (this repo has shipped each of these)

- `[ test ] && cmd` as the **last** statement of a function (or `{ }` group):
  a false test becomes the return value and trips `set -e`. Use `if … fi`.
- `local x="$(cmd)"` hides `cmd`'s failure; declare, then assign.
- `cmd | grep -q` with pipefail: `grep -q` exits early, `cmd` gets SIGPIPE → the
  pipeline "fails". Capture first, or `|| true` deliberately.
- `$(…)` subshells lose variable assignments — caches must live in the main shell.

## GNU vs BSD tools (the host is often macOS)

| Don't | Do |
|---|---|
| `sed -i 's/…/'` (GNU) / `sed -i ''` (BSD) | write to a temp file + `mv`, or `awk` |
| `stat -c %a` | `stat -c '%a' f 2>/dev/null \|\| stat -f '%Lp' f` |
| `readlink -f`, `realpath` | `cd "$(dirname "$p")" && pwd` |
| `date -d`, `grep -P`, `base64 -w0`, `xargs -r`, `sort -V`, `timeout`, `seq -w` | portable equivalents; `timeout` doesn't exist on macOS |
| `mktemp -p` / `--suffix` | `mktemp` or `mktemp -d` |
| `echo -e`, `echo -n` | `printf` |
| `hostname -I`, `ip`, `ss` on the **host** | fine only inside Linux containers |

macOS filesystems are usually **case-insensitive**; paths under `/Users` may
contain spaces (quote everything; `file://` URLs with spaces break curl).

## POSIX sh (entrypoint, services, hooks)

No `[[ ]]`, arrays, `function` keyword, `==` in `[ ]`, `$'…'`, `source` (use
`.`), `<<<`, `{a,b}` brace expansion, `pipefail`. `local` works in dash but not
in every sh — keep usage consistent with the existing entrypoint. Run
`sh -n` on the materialised file (`CONTEXT_DIR=/tmp/ctx ./nixenv.sh status`).

## Engines: Docker vs Podman, Desktop vs Linux

- Every call goes through `"$ENGINE"`; image names through `img` (podman needs
  `docker.io/` for short names).
- **Rootless podman** needs `--userns=keep-id`; **rootful** podman rejects it —
  `engine_userns` decides from `ENGINE_ROOTLESS`.
- `network inspect` formats differ (`.IPAM.Config` vs `.Subnets`); container DNS
  needs a user-defined network (netavark on podman).
- **Docker Desktop** resets an EMPTY named volume's owner to root on next mount
  (hence the `.keep` files); bind mounts only work for shared host paths;
  `--privileged` works (the dev sidecars rely on it) — rootless podman limits it.
- Rootless podman can't bind host ports < 1024 without sysctl changes (proxy
  ports 8080/8443 there).
- Anything run as the non-root project user can't write `/`, `/var/log`, `/etc`
  (except the bind-mounted `/etc/hosts`): writable paths live under `$HOME`.

## Method

1. For every changed line, name the shell it runs in (table above).
2. `bash -n` / `sh -n`; `shellcheck -s bash nixenv.sh` (in the dev project) —
   triage, don't paste its output wholesale.
3. When a construct is doubtful, prove it: a 3-line script under `bash --posix`
   or `docker run --rm debian:stable-slim sh -c '…'`. CI runs the unit suite on
   **macOS** — suggest a test when a construct could differ there.

## How to report

```
[breaks|risky|nit] <title> — <macOS|Linux|podman|Docker Desktop|debian-slim>
  where:   file:<line>
  why:     the rule above it violates, with the failing behaviour
  fix:     the portable form
```
