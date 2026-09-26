# Releasing nixenv

Pushing a `vX.Y.Z` tag is the whole release. `.github/workflows/release.yml`
verifies it, publishes a GitHub release, and updates the Homebrew tap.

```sh
# 1. bump the version IN the script — it is the single source of truth
sed -i '' 's/^NIXENV_VERSION=.*/NIXENV_VERSION="0.2.0"/' nixenv.sh

# 2. prove it's releasable locally (the workflow runs the same suite)
./tests/run.sh

# 3. commit, then tag
git commit -am "release 0.2.0"
git tag -a v0.2.0 -m "nixenv 0.2.0"
git push && git push --tags
```

Then watch **Actions → release**. That's it — steps 4+ are automatic.

---

## One-time setup

Neither is needed to publish a GitHub release; both are needed for `brew` to see
the new version.

**1. The tap repository.** The `homebrew-` prefix is how `brew` resolves
`rande/nixenv`:

```sh
gh repo create rande/homebrew-nixenv --public \
  --description "Homebrew tap for nixenv"
git clone https://github.com/rande/homebrew-nixenv
mkdir -p homebrew-nixenv/Formula
cp packaging/homebrew/Formula/nixenv.rb homebrew-nixenv/Formula/
cd homebrew-nixenv && git add -A && git commit -m "nixenv formula" && git push
```

**2. A `TAP_TOKEN` secret** on *this* repo (Settings → Secrets and variables →
Actions). A fine-grained PAT with **Contents: write** on `rande/homebrew-nixenv`.
The default `GITHUB_TOKEN` cannot push to another repository, which is the whole
reason this secret exists.

Without it the release still succeeds — the tap job skips with a `::notice::` and
you finish by hand (see [Manual fallback](#manual-fallback)).

## What the tag triggers

Three jobs, each gated on the one before it, so nothing is published if the
checks fail:

```
verify ──► release ──► formula
```

| Job | Does | Fails when |
|---|---|---|
| **verify** | tag vs `NIXENV_VERSION`, `bash -n`, unit suite, `nixenv --version` smoke test | the tag disagrees with the script, or any test fails |
| **release** | `gh release create --generate-notes`, attaching `nixenv.sh` + `LICENSE` | the tag already has a release |
| **formula** | `update-formula.sh`, commit to `main`, push to the tap | `TAP_TOKEN` missing → *skips*, doesn't fail |

### Why verify's first check matters most

The Homebrew formula's version comes from the tag, and its `test` block asserts
`nixenv --version` equals it. A tag that disagrees with `NIXENV_VERSION` would
therefore ship a formula that fails on **every user's machine and never on
yours**. That check is the only thing standing between a typo and that outcome.

### Why the formula can only be updated after the tag

The formula's `sha256` is of the source tarball **GitHub generates for the tag**,
which does not exist until the tag is pushed. So:

- the formula cannot be correct at tag time;
- the tagged commit still carries the *previous* `sha256`;
- the **tap**, not the tag, is what `brew` actually reads.

That's normal for Homebrew, but it surprises people who expect the tag to be
self-contained.

## Verifying a release

```sh
gh release view v0.2.0                          # notes + assets
curl -fsSL https://github.com/rande/nixenv/releases/latest/download/nixenv.sh \
  | head -3                                     # the single-file install path
brew update && brew upgrade nixenv && nixenv --version
```

Before publishing, you can also exercise the formula locally:

```sh
brew install --build-from-source packaging/homebrew/Formula/nixenv.rb
brew test nixenv          # works without Docker: --version/--help need no engine
brew audit --strict --formula packaging/homebrew/Formula/nixenv.rb
brew uninstall nixenv
```

## When something goes wrong

**`verify` failed.** Nothing was published. Fix, then re-tag — a tag can't be
moved once pushed without deleting it:

```sh
git tag -d v0.2.0
git push origin :refs/tags/v0.2.0
# ...fix, commit...
git tag -a v0.2.0 -m "nixenv 0.2.0" && git push --tags
```

**Tag and `NIXENV_VERSION` disagree.** The error names both values. Bump the
script, commit, then delete and re-push the tag as above.

**The formula job skipped.** `TAP_TOKEN` is unset. Finish by hand below.

**The formula is wrong / the sha doesn't match.** Re-run the helper against the
existing tag; it is idempotent and re-verifies the version inside the tarball:

```sh
./packaging/homebrew/update-formula.sh 0.2.0            # rewrite url + sha256
./packaging/homebrew/update-formula.sh 0.2.0 --check    # verify only, no writes
```

**`brew` still installs the old version.** `brew update` first — the tap is a git
repo and needs fetching.

## Manual fallback

No Actions involved:

```sh
# after the tag is pushed and the release exists
./packaging/homebrew/update-formula.sh 0.2.0
cp packaging/homebrew/Formula/nixenv.rb ../homebrew-nixenv/Formula/
(cd ../homebrew-nixenv && git commit -am "nixenv 0.2.0" && git push)
```

`update-formula.sh` refuses if the script's version, the requested version, or
the version inside the downloaded tarball disagree — the same guards the workflow
relies on, because it calls this exact script.

## Version numbering

`NIXENV_VERSION` at the top of `nixenv.sh` is the source of truth; the tag
mirrors it with a `v` prefix. Only `v[0-9]+.[0-9]+.[0-9]+` triggers the workflow,
so `v0.2` or `v0.2.0-rc1` will push a tag that does nothing.

Rough guidance, given users pin nothing and `brew upgrade` is the norm:

- **patch** — fixes that need no action from anyone.
- **minor** — new commands, new templates, new config files.
- **major** — anything that invalidates existing projects: a change to the
  per-project layout under `~/.nixenv/projects/`, volume naming, or the base
  flake dropping something projects relied on.

Bumping the pinned nixpkgs in the base flake deserves at least a minor, since it
rebuilds every user's shared store.
