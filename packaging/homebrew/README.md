# Homebrew packaging

`nixenv` is one self-contained bash script, so the formula has **no dependencies
and no build step**. What users get:

```sh
brew install rande/nixenv/nixenv
nixenv --version
```

## Why a tap, not homebrew-core

homebrew-core has notability requirements and routes every version bump through
its own review queue. A personal tap is a plain GitHub repo you own, publishes
instantly, and the install command is barely longer. You can always graduate to
core later — the formula file itself is unchanged.

## One-time: create the tap

The repo name **must** be `homebrew-<tap>`; that prefix is how `brew` resolves
`rande/nixenv`.

```sh
gh repo create rande/homebrew-nixenv --public \
  --description "Homebrew tap for nixenv"
git clone https://github.com/rande/homebrew-nixenv
mkdir -p homebrew-nixenv/Formula
cp packaging/homebrew/Formula/nixenv.rb homebrew-nixenv/Formula/
cd homebrew-nixenv && git add -A && git commit -m "nixenv formula" && git push
```

## Releasing a version

See **[RELEASING.md](../../RELEASING.md)** — the whole process, the automated and
manual paths, and how to recover from a bad tag live there so there is one
description of it.

The formula-specific part: `update-formula.sh <version>` rewrites `url` and
`sha256` together from the real GitHub tarball, and refuses when the script's
version, the version you asked for, or the version *inside* the downloaded
tarball disagree. Those guards exist because a formula whose `test` block fails
breaks for users, never for you. `--check` verifies without writing.

## Verifying before you publish

```sh
brew install --build-from-source packaging/homebrew/Formula/nixenv.rb
brew test nixenv
brew audit --strict --formula packaging/homebrew/Formula/nixenv.rb
brew uninstall nixenv
```

`brew test` works without Docker on purpose: `--version` and `--help` are
dispatched before `materialize_context`, so they need no engine, no network and
write nothing.

## Notes on the formula

- **`bin.install "nixenv.sh" => "nixenv"`** is the rename that puts `nixenv` on
  PATH.
- **No `depends_on "bash"`.** The script holds the Bash 3.2 line deliberately,
  so macOS's system bash suffices. If that ever changes, this needs
  `depends_on "bash"` *and* a shebang change — the formula won't notice on its
  own.
- **Docker/Podman aren't dependencies.** Homebrew deprecated optional and
  recommended deps, and a cask can't be a formula dep, so the engine is a
  caveat. `nixenv` already fails with a clear message when no engine is found.
- **Templates are installed to `share/nixenv/templates`** so a release pins its
  own templates. Normally `resolve_template` fetches them from `TEMPLATE_BASE`
  over https, which means a tagged nixenv can otherwise pull templates from
  `main` that have moved on. Opt into the local copies with:

  ```sh
  export TEMPLATE_BASE="file://$(brew --prefix)/share/nixenv/templates"
  ```

  (`resolve_template` builds `$TEMPLATE_BASE/<name>.nix` and curls it; curl
  handles `file://`, so short names keep working offline.)
- **`nixenv install` is blocked** under a Homebrew prefix. It would copy the
  script to `/usr/local/bin`, creating a second copy that `brew upgrade` never
  touches and that shadows — or is shadowed by — the managed one.
