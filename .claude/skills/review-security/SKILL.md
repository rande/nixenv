---
name: review-security
description: Security review of nixenv changes — container escapes, cross-project access, egress bypass, secret leaks, and trust of untrusted inputs (archives, repos, flakes, templates). Use when asked for a security review, when a change touches mounts, networking, the proxy/squid/Caddy config, ssh, imports/exports, tokens or credentials, or before a release.
allowed-tools: Read, Grep, Glob, Bash
---

# Security review for nixenv

## Threat model (from `tasks/security/README.md`)

A project container is a sandbox for **code you half-trust**: a cloned repo, its
dependencies, its startup hook, its flake. An escape is anything that reaches:

1. **the host** — files outside the project's own dirs, the engine, host ports;
2. **another project** — its files, shell, services, Claude state;
3. **the network beyond the allowlist** — including via DNS.

Also in scope: secrets leaving the machine (archives, logs, `NIX_CONFIG`,
`docker inspect`-visible env) and inputs nixenv consumes from outside
(archives, templates, repo files such as `.nixenv/hooks.sh` and `.nixenv/sv/*`).

Read `tasks/security/*.md` first: they document past findings, their fixes, and
the **accepted limits** — don't re-report those (shared Claude token readable by
every project; project flake builds usually unsandboxed with store write access;
hostname allowlists can't police allowed hosts; the `dev/` engine sidecars are
root on the engine VM by design).

## Where to look, by change type

| Change touches… | Check |
|---|---|
| `-v`/bind mounts, files under `~/.nixenv/projects/<p>/` | Symlinks followed on the host? A value with `:` smuggling mount options? Path built from untrusted input (`..`, absolute)? Read-only where it can be? |
| `import`, archives, templates, anything from a repo | Treated as untrusted? Regular files only, validated, nothing that changes how a container is *created* applied silently (`extra-parameters`, `ports`, `unrestricted`). `--yes` must not grant these. |
| squid config (`write_egress_configs`) | Rule order: nothing that resolves a name (`dst`) before the per-project name gate. Run `tests/squid_acl_sim.py` against the generated config for the new case: verdict **and** `dns=no` for refused names. |
| Caddy (`write_caddyfile`) | Route regex limited to project-name chars; cross-project guard still before `reverse_proxy` inside `route {}`. |
| Networks, ports, relays | Published on `127.0.0.1` only unless the user asked; restricted projects stay on their `--internal` net; relays not reachable from project networks. |
| ssh | Key-only; `authorized_keys` read-only and host-generated; host key pinned; `%n` not `%k` for sessions. |
| `docker run` flags | Hardening (`container_hardening_args`) still applied, before `extra_args`; no new `--privileged`, capabilities, devices or `seccomp=unconfined` by default. |
| Tokens, credentials | Never in an export by default; masked in messages; validated before landing in config (`valid_github_token` pattern); files mode 600; project builds never get them. |
| Anything written into a config file or command line | Injection: newlines, quotes, `#`, spaces — can a value add a directive? |
| Prompts, `confirm_tty` | No TTY must mean "deny", never "grant". |

## Method

1. Map every new **input → sink**: where does data come from (user, repo,
   archive, network, another container) and where does it land (mount, flag,
   config file, shell command, log)?
2. For each, try to write the malicious value. If you can, write the exploit
   steps; if you can't, say why (the validation that stops it).
3. Prefer demonstrating over asserting: run the generator with a hostile value
   (unit tests source `nixenv.sh`; see `tests/unit/27-import-hostile-meta.sh`).

## How to report

```
[critical|high|medium|low] <title>
  boundary:  host | cross-project | egress | secret
  path:      step-by-step exploit from the attacker's position
  where:     nixenv.sh:<line> (function)
  fix:       the change, and the test that proves the attack now fails
```

Critical = host escape or cross-project code execution without user action.
Offer to file each finding as `tasks/security/SEC-NN-<slug>.md` in the existing
format. Report only what you verified; mark hypotheses as such.
