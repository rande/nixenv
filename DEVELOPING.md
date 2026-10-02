# Developing nixenv

How to set up a working environment for changing nixenv itself, run its tests,
and review changes. Releasing is covered in [RELEASING.md](RELEASING.md); the
design and its hard-won rules are in [`specs/`](specs/README.md), one rule per
file — read the ones that govern a file before changing it ([AGENTS.md](AGENTS.md)
explains how).

Two ways to work:

- **Inside a nixenv project (recommended).** Install nixenv, `init` the nixenv
  repo as a project, ssh in and hack. Real Docker and Podman engines run next to
  the project, so you can boot nested projects and run the whole test suite
  without touching your own projects. All you need on your Mac is nixenv itself.
- **In a plain clone on your Mac.** Quickest for the unit tests alone.

> **Which nixenv runs?** Two copies are involved, and they have different jobs.
> The `nixenv` on your Mac (Homebrew, say) only *hosts* the dev project — any
> recent release is fine. The code you're changing is the checkout **inside**
> the project, and there `nixenv` runs that checkout (`/app/nixenv.sh`). The
> only way to test stale code by accident is to use the installed `nixenv` while
> editing a clone on your Mac — in a clone, run `./nixenv.sh`.

## 1. Inside a nixenv project (recommended)

A nixenv project container runs as your user with every capability dropped, so
no container engine can run *inside* it. `dev/engines.sh` instead starts Docker
and Podman as two privileged **sidecar** containers next to the project:

```
 your Mac ─ engine ─┬─ nixenv-nixenv            (your dev project: repo, tests, clients)
                    │        │ /var/run/nixenv/{docker,podman}.sock
                    ├─ nixenv__nixenv-dind     (dockerd)   ─┐ mount the project's home
                    └─ nixenv__nixenv-podman   (podman API) ┘ and repo at the SAME paths
```

The project talks to them over Unix sockets in a volume only it mounts. The
sidecars see the project's home and repo at the same paths the project does,
which is what lets a nested nixenv bind-mount its own files.

> **Security.** The sidecars are root on your engine's VM, and code in the dev
> project can drive them — so it effectively has root there and full network
> access, whatever the project's egress allowlist says. Use this for your own
> nixenv checkout, not for code you don't trust.
>
> Built for Docker (Docker Desktop, or rootful Docker on Linux). Privileged
> containers under rootless Podman are limited.

### Set it up (on your Mac)

```sh
brew install rande/nixenv/nixenv
nixenv build                                          # the shared toolchain, once
nixenv init nixenv git@github.com:rande/nixenv.git    # or your fork / an https URL
nixenv run nixenv

# engines.sh runs on your Mac: copy it out of the checkout you just cloned
docker exec nixenv-nixenv cat /app/dev/engines.sh > engines.sh && chmod +x engines.sh
./engines.sh up nixenv                                # the sidecars + the socket mount

nixenv build nixenv --dir=dev                         # dev/flake.nix (--dir is remembered)
nixenv stop nixenv && nixenv run nixenv               # recreate: picks up sockets + tools
nixenv ssh-config --install                           # once: enables `ssh <project>`
ssh nixenv
```

A copied-out `engines.sh` uses the `nixenv` installed on your Mac for its naming
helpers (it says so if that one is too old). Working from a clone on your Mac
instead? It's the same with `./nixenv.sh` and `./dev/engines.sh`.

The project is egress-restricted like any other: only `github.com` (from the
clone URL) is allowed at first. The nested engines don't need more — they pull
over their own network — but `gh` inside does: `nixenv allow nixenv api.github.com`.

### What you get inside

The dev flake installs, inside the project:

- `nixenv` — **your checkout's `./nixenv.sh`**, so the code you're editing is
  what runs, from any directory;
- `docker` and `podman` — the clients, already pointed at the sidecars (the
  engines themselves run in the sidecars; a project container can't run one);
- `nixenv-docker` / `nixenv-podman` — `nixenv` pinned to one engine each (below);
- `python3`, `shellcheck`, `shfmt`, `jq`, `gh`.

### Work inside it

```sh
cd /app                        # the repo (your project's app volume)
docker info && podman info     # both sidecars answer
./tests/run.sh                 # unit tests
./tests/run-in-docker.sh       # the full suite, via the Docker sidecar
```

Boot a nested project — the hello example:

```sh
nixenv build                                                  # nested store (slow the first time; kept in the sidecar)
nixenv init hello --template=examples/hello/flake.nix --yes
nixenv run hello
docker exec nixdev-hello /nix/var/nix/profiles/shared/bin/curl -s localhost:8080 | grep nixenv-hello-ok
```

Nested ports and the nested proxy live in the sidecar's network: reach them with
`docker exec`, not from your browser.

**Nested names are `nixdev-*`, never `nixenv-*`.** The dev wrappers (`nixenv`,
`nixenv-docker`, `nixenv-podman`) default `CONTAINER_PREFIX=nixdev`, and every
engine-side name follows the prefix: containers `nixdev-<p>`, `nixdev__proxy`,
`nixdev__egress`, volumes `nixdev_<p>_*`, networks `nixdev_net*` and the store
volume `nixdev__nixos_store`. So even on an engine shared with your hosted
nixenv, a nested `stop`, `delete` or `build` can only touch nested things. An
explicit `CONTAINER_PREFIX=…` still wins.

Nested projects made before this used the `nixenv` prefix and are not picked up
by the new names. Either keep driving them with `CONTAINER_PREFIX=nixenv
nixenv-docker …`, or move them once:

```sh
CONTAINER_PREFIX=nixenv nixenv-docker stop          # the old nested containers
for p in $(ls ~/.nixenv-dev/docker/.nixenv/projects); do
  for k in app home databases; do
    docker volume create "nixdev_${p}_$k" >/dev/null
    docker run --rm -v "nixenv_${p}_$k":/from:ro -v "nixdev_${p}_$k":/to \
      debian:stable-slim cp -a /from/. /to/
  done
done
nixenv-docker build                                 # builds nixdev__nixos_store
nixenv-docker build <p>                             # each project flake, then run
```

(`NIX_VOLUME=nixenv__nixos_store` reuses the old nested store instead of
building a new one — fine inside the sidecar, but on a SHARED engine that is
the hosted store, and a nested `build` would rewrite it.) Remove the old
`nixenv_*` volumes once the moved projects work. The first nested `build` may ask for a
GitHub token — see "GitHub token" in the README.

### One project on Docker, one on Podman

`nixenv-docker` and `nixenv-podman` run your checkout pinned to one engine.
**Each project belongs to exactly one engine**: each command keeps its own
nixenv state (`~/.nixenv-dev/docker`, `~/.nixenv-dev/podman`), so a project
created with one is invisible to the other, and the two engines' proxies never
share config files.

```sh
nixenv-docker build                   # one nested store per engine (slow once each)
nixenv-docker init hello-docker --template=examples/hello/flake.nix --yes
nixenv-docker run hello-docker
docker exec nixdev-hello-docker /nix/var/nix/profiles/shared/bin/curl -s localhost:8080 | grep nixenv-hello-ok

nixenv-podman build
nixenv-podman init hello-podman --template=examples/hello/flake.nix --yes
nixenv-podman run hello-podman
podman exec nixdev-hello-podman /nix/var/nix/profiles/shared/bin/curl -s localhost:8080 | grep nixenv-hello-ok

nixenv-docker projects                # lists only the Docker ones
```

Plain `nixenv` uses `~/.nixenv` and the engine picked the first time (Docker
when its sidecar is up; remembered in `~/.nixenv/engine`).

### Manage the sidecars (on your Mac)

```sh
./engines.sh status nixenv
./engines.sh down nixenv            # stop them; nested images and store are kept
./engines.sh down nixenv --purge    # …and delete those too
./engines.sh up nixenv --docker     # only one engine (or --podman)
```

## 2. In a plain clone on your Mac

You need Docker or Podman, Bash (the macOS one is fine) and git. `gh` (the
GitHub CLI) is only needed to release.

```sh
git clone https://github.com/rande/nixenv && cd nixenv
./tests/run.sh                  # unit tests: seconds, no container engine needed
```

Run the tool as **`./nixenv.sh`** here — an installed `nixenv` is a snapshot of
some release, not the code you're editing.

## 3. Tests

The same commands work in both setups (inside the dev project, from `/app`).

| Command | What it runs | Needs |
|---|---|---|
| `./tests/run.sh` | unit tests — they `source nixenv.sh` and test functions directly | nothing |
| `./tests/run.sh tests/unit/08-egress-config.sh` | one file | nothing |
| `./tests/run.sh integration` | real containers, under an isolated `nxt-*` prefix | an engine; reuses your built store |
| `./tests/run-in-docker.sh` | everything, inside a disposable privileged docker-in-docker | Docker; leaves your projects untouched |

Integration tests clean up after themselves by prefix, but they do use your
engine — prefer `run-in-docker.sh`, or the dev project, if you have projects you
care about.

Inside the dev project, two things differ. Point `NIXTEST_HOME` under
`/home/app` (e.g. `NIXTEST_HOME=/home/app/.cache/nxt-tests`): the sidecar
daemon resolves bind-mount paths on its own filesystem, which shares only the
home and app volumes, so the default `/tmp/nixenv-tests` fails with "not a
directory". And ports published on `127.0.0.1` land on the SIDECAR's
loopback, not the project's, so checks that `wait_tcp`/`curl` a host port
(06, the ssh relay in 07, 16) can't pass there; the rest of those tests can.
`integration/19-capture.sh` takes `NIXENV_TEST_PROFILE=<profile path>` to run
against a profile with mitmproxy without rebuilding the shared one.

Every change to `nixenv.sh` needs the unit suite green. New logic gets a unit
test (`tests/unit/NN-name.sh`); anything that touches containers also gets an
integration test. Tests that grep the source should pipe through `code_only`
(see `tests/lib.sh`) — this repo explains each trap in a comment next to the
fix, and a naive grep matches the comment.

Quick checks without the suite:

```sh
bash -n nixenv.sh
CONTEXT_DIR=/tmp/ctx ./nixenv.sh status   # writes the embedded files out
sh -n /tmp/ctx/entrypoint.sh              # the entrypoint is POSIX sh
```

### Where things are

| Path | What |
|---|---|
| `nixenv.sh` | the whole tool, including its base flake, entrypoint and dotfiles (heredocs in `materialize_context()`) |
| `tests/` | unit + integration suites, `lib.sh` harness, `squid_acl_sim.py` |
| `templates/` | project templates (one file = a project's `flake.nix`) |
| `examples/hello/` | the smallest project: nginx serving one page |
| `dev/` | the dev environment: `flake.nix` and `engines.sh` |
| `docs/` | the GitHub Pages one-pager |
| `packaging/homebrew/`, `release.sh`, `.github/workflows/` | releasing |
| `tasks/security/` | security findings, fixes and accepted limits |
| `.claude/skills/` | review skills (below) |

## 4. Reviewing changes

Three Claude Code skills in `.claude/skills/` review a change from different
angles. In Claude Code, working in this repo (the CLI is in the dev project):

| Skill | Looks at |
|---|---|
| `/review-principal-engineer` | design, invariants from `specs/`, failure modes, migrations of users' existing `~/.nixenv` state, tests and docs |
| `/review-security` | escapes to the host or another project, egress bypass, secrets, untrusted inputs — against the threat model in `tasks/security/` |
| `/review-linux-macos` | Bash 3.2 and BSD tools on macOS, POSIX sh in the entrypoint, Docker vs Podman vs Docker Desktop differences |

Ask for "a full review of this branch" and all three apply; each reports
findings with severity, location, evidence and a fix.

## 5. Before you push

- `./tests/run.sh` is green (CI also runs it on macOS, where Bash 3.2 lives).
- The `specs/` file for every rule you added or changed is up to date (the
  *why* a future maintainer would otherwise trip over).
- `README.md` uses bare `nixenv` in examples; specs and `AGENTS.md` use `./nixenv.sh`.
- Releasing: bump `NIXENV_VERSION`, commit, push, then `./release.sh` ([RELEASING.md](RELEASING.md)).
