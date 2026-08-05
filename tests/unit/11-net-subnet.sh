#!/usr/bin/env bash
# net_subnet: parses docker (.IPAM.Config) and podman (.Subnets) formats.
source "$(dirname "$0")/../lib.sh"
source_nixenv

# Fake engine: docker-style answers on the IPAM format, podman on .Subnets.
fake_docker() { case "$*" in *IPAM*) echo "10.89.1.0/24 ";; *) return 1;; esac; }
fake_podman() { case "$*" in *IPAM*) return 1;; *Subnets*) echo "10.90.2.0/24 ";; esac; }

ENGINE=fake_docker
assert_eq "$(net_subnet somenet)" "10.89.1.0/24" "docker format"

ENGINE=fake_podman
assert_eq "$(net_subnet somenet)" "10.90.2.0/24" "podman fallback format"

fake_none() { return 1; }
ENGINE=fake_none
assert_eq "$(net_subnet somenet)" "" "unknown → empty (caller skips project)"
