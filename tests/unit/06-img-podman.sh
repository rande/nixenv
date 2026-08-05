#!/usr/bin/env bash
# img(): docker passthrough; podman gets docker.io/ for short names only.
source "$(dirname "$0")/../lib.sh"
source_nixenv

ENGINE=docker
assert_eq "$(img debian:stable-slim)" "debian:stable-slim" "docker passthrough"

ENGINE=podman
assert_eq "$(img debian:stable-slim)"      "docker.io/debian:stable-slim"   "podman short name"
assert_eq "$(img nixos/nix:2.32.8)"        "docker.io/nixos/nix:2.32.8"     "podman repo path"
assert_eq "$(img ghcr.io/foo/bar:1)"       "ghcr.io/foo/bar:1"              "podman full registry kept"
assert_eq "$(img localhost/img:1)"         "localhost/img:1"                "podman localhost kept"
assert_eq "$(img reg.example.com:5000/x)"  "reg.example.com:5000/x"         "podman host:port kept"
