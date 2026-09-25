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

**Automated.** Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`,
which verifies the tag matches `NIXENV_VERSION`, runs the unit suite, creates the
GitHub release (attaching `nixenv.sh` and `LICENSE`), then runs
`update-formula.sh` and pushes the result to the tap:

```sh
sed -i '' 's/^NIXENV_VERSION=.*/NIXENV_VERSION="0.2.0"/' nixenv.sh
./tests/run.sh
git commit -am "release 0.2.0"
git tag -a v0.2.0 -m "nixenv 0.2.0" && git push && git push --tags
```

The tap step needs a **`TAP_TOKEN`** repo secret — a fine-grained PAT with
Contents: write on `rande/homebrew-nixenv`. The default `GITHUB_TOKEN` cannot
push to another repository. Without it the job skips with a notice and the
release still succeeds; finish by hand with the manual steps below.

### Manual release

The order matters: the sha256 is computed from the tarball GitHub generates, so
the tag has to exist first.

```sh
# 1. bump the version IN the script (single source of truth) and commit
sed -i '' 's/^NIXENV_VERSION=.*/NIXENV_VERSION="0.2.0"/' nixenv.sh
./tests/run.sh                                    # 21-homebrew-formula.sh guards the sync
git commit -am "release 0.2.0"

# 2. tag and push — GitHub builds the tarball from this
git tag -a v0.2.0 -m "nixenv 0.2.0" && git push --tags

# 3. rewrite url + sha256 from the real tarball
./packaging/homebrew/update-formula.sh 0.2.0

# 4. publish to the tap
cp packaging/homebrew/Formula/nixenv.rb ../homebrew-nixenv/Formula/
(cd ../homebrew-nixenv && git commit -am "nixenv 0.2.0" && git push)
```

`update-formula.sh` refuses to run when `NIXENV_VERSION` in the script doesn't
match the version you asked for, and re-checks the version *inside* the
downloaded tarball. Both exist because a formula whose `test` block fails only
breaks for users, never for you. `--check` verifies without writing, which is
what CI should run.

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
