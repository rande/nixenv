#!/usr/bin/env bash
# forge_host_from_url extracts the forge domain from every clone-URL form.
source "$(dirname "$0")/../lib.sh"
source_nixenv

assert_eq "$(forge_host_from_url 'https://gitlab.example.com/team/app.git')" "gitlab.example.com"
assert_eq "$(forge_host_from_url 'http://forge.local/x.git')"              "forge.local"
assert_eq "$(forge_host_from_url 'git@github.com:me/app.git')"             "github.com"
assert_eq "$(forge_host_from_url 'ssh://git@gitlab.com:2222/g/p.git')"     "gitlab.com"
assert_eq "$(forge_host_from_url 'https://user@bitbucket.org/x/y.git')"    "bitbucket.org"
assert_eq "$(forge_host_from_url 'git://host.tld/repo.git')"               "host.tld"
assert_eq "$(forge_host_from_url '/local/path/repo')"                      ""
