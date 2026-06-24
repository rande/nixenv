# nixenv

A self-contained shell tool for spinning up disposable, per-project development
containers that share one common set of tools through a single Nix store.

Instead of baking every tool into a Docker image, `nixenv.sh` downloads all
dependencies once into a standalone Docker volume (the Nix store) and lets each
project container mount that store read-only. Containers start instantly and
every project shares the same pinned toolchain.

## How it works

1. **Self-contained script.** Everything — `flake.nix`, a reference
   `Dockerfile`, the runtime entrypoint, and the home skeleton — is embedded in
   `nixenv.sh`. On every run it writes these into `$CONTEXT_DIR`
   (default `~/.nixenv/context`) and builds from there. You can copy just
   `nixenv.sh` anywhere and it recreates its own context.
2. **Standalone volume.** A named Docker volume (`nixos-store`) holds `/nix`.
3. **Builder container.** A short-lived `nixos/nix` container realises every
   dependency from the flake into the volume and installs them into a shared
   profile (`/nix/var/nix/profiles/shared`) that also lives in the volume.
4. **Runtime container.** A lightweight `debian:stable-slim` container mounts the
   volume read-only at `/nix`, creates a non-root `app` user, and launches
   `zsh` + `starship`. Nix binaries reference their own loader/libs by absolute
   `/nix` path, so the slim base's libc is irrelevant.

## Requirements

- Docker (daemon running)
- Bash

No host Nix install is needed — all Nix work happens inside containers.

## Quick start

```sh
./nixenv.sh build                 # download all deps into the volume (slow once)
./nixenv.sh init myapp            # scaffold a project, prompts for git identity
./nixenv.sh run myapp             # dev shell, repo mounted at /app
```

Clone a repo while initialising:

```sh
./nixenv.sh init myapp git@github.com:me/app.git
```

## Commands

- `build` — (re)write context, then download all flake deps into the volume.
- `init <project> [git-url]` — scaffold `<project>/{home,repo}`, prompt for git
  name/email, and optionally clone `git-url` into `repo/`.
- `run <project> [cmd...]` — start the runtime container (no cmd = interactive
  zsh; otherwise runs the command in the shared environment).
- `up <project> [cmd...]` — build if needed, then run.
- `shell <project>` — alias for `run <project>`.
- `projects` — list initialised projects.
- `update` — refresh `flake.lock`, then rebuild into the volume.
- `status` — show context, volume, and shared-profile state.
- `clean` — delete the standalone volume (removes all shared packages).

## Project layout

Projects live under `projects/` (next to the script by default):

```
projects/<name>/
  home/   → copied into /home/app   (.ssh, .zshrc, .gitconfig, configs)
  repo/   → mounted at /app         (your code; the WORKDIR)
```

A new project's `home/` is seeded from the embedded home skeleton. The runtime
container *copies* `home/` into `/home/app` so SSH key permissions can be
enforced (`700` dir, `600` files) regardless of how the host bind-mount exposes
ownership. Drop your SSH keys into `projects/<name>/home/.ssh/` and your code
into `projects/<name>/repo/`.

Git identity is stored per project in `home/.gitconfig.identity`, which the
project's `.gitconfig` includes — so re-running `init` never duplicates the
`[user]` block.

## Toolchain

The shared profile includes git, zsh + oh-my-zsh + starship, common CLI tools
(ripgrep, fd, fzf, bat, jq, delta, lazygit, tmux, zellij, …), and language
runtimes: Node 22 (with `npx`), Go, Rust (rustup), PHP 8.3 + Composer,
Python 3.12, and `uv` (with `uvx`). Edit the embedded `flake.nix` block in
`nixenv.sh` and re-run `build` to change the set.

## Configuration

Override via environment variables:

- `CONTEXT_DIR` (default `~/.nixenv/context`)
- `NIX_VOLUME` (default `nixos-store`)
- `BUILDER_IMAGE` (default `nixos/nix:2.32.8`)
- `RUNTIME_IMAGE` (default `debian:stable-slim`)
- `PROJECTS_DIR` (default `projects/` beside the script)
- `APP_USER` (default `app`)
- `GIT_USER_NAME` / `GIT_USER_EMAIL` — skip the interactive git prompt.

## Notes

- `projects/` is git-ignored: it holds SSH keys, repos, and local state.
- The Nix store volume persists across runs; `clean` is the only thing that
  removes it.
