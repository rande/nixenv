# typed: false
# frozen_string_literal: true

# Homebrew formula for nixenv.
#
# nixenv is one self-contained bash script, so this is about as simple as a
# formula gets: no build step, no dependencies (the script holds the Bash 3.2
# line deliberately, so macOS's system bash is enough).
#
# Publishing: copy this file to Formula/nixenv.rb in the tap repo
# (github.com/rande/homebrew-nixenv) — see ../README.md. Run
# ../update-formula.sh <version> first; it rewrites url + sha256 together, which
# is the pair that is easy to get out of step by hand.
class Nixenv < Formula
  desc "Per-project dev containers sharing one pinned Nix store"
  homepage "https://github.com/rande/nixenv"
  url "https://github.com/rande/nixenv/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "GPL-3.0-or-later"
  head "https://github.com/rande/nixenv.git", branch: "main"

  def install
    # Renamed on install: the repo file is nixenv.sh, the command is `nixenv`.
    bin.install "nixenv.sh" => "nixenv"

    # Templates are normally fetched from TEMPLATE_BASE over https. Shipping
    # them pins them to THIS release and allows offline use — see caveats.
    pkgshare.install "templates"
    doc.install "README.md"
  end

  def caveats
    <<~EOS
      nixenv drives containers but installs none. Pick an engine:
        brew install --cask docker      # or:  brew install podman

      Optional, for trusted HTTPS on *.nixenv.localhost:
        brew install mkcert

      First use downloads the shared Nix store into a container volume
      (slow once, then shared by every project):
        nixenv build

      This release's templates are installed locally. To use them instead of
      fetching from GitHub — pinning templates to the nixenv version you have:
        export TEMPLATE_BASE="file://#{opt_pkgshare}/templates"
    EOS
  end

  test do
    # Both must work with no container engine, no network and no writes.
    assert_match "nixenv #{version}", shell_output("#{bin}/nixenv --version")
    assert_match "Usage:", shell_output("#{bin}/nixenv --help")

    # The shipped templates must be the real thing, not an empty directory.
    assert_predicate pkgshare/"templates/windmill.nix", :exist?
    assert_match "nixenv:description", (pkgshare/"templates/windmill.nix").read

    # Without an engine nixenv must fail cleanly rather than hang or crash.
    output = shell_output("#{bin}/nixenv status 2>&1", 1)
    refute_match "Traceback", output
  end
end
