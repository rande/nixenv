---
paths:
  - "nixenv.sh"
---

# SSH rules (Key-only login, pinned host key, zmx sessions)

These rules are specified one per file under `specs/ssh/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- SSH-01 Container sshd accepts only the host-generated project key: @../../specs/ssh/001-key-only.md
- SSH-02 The container host key is pinned: @../../specs/ssh/002-host-key-pinning.md
- SSH-03 Host ssh config with zmx sessions: @../../specs/ssh/003-ssh-config-zmx.md
