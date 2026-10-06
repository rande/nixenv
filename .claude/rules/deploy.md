---
paths:
  - "nixenv.sh"
  - "README.md"
---

# Deploy rules (Throwaway deploy container with the forwarded agent)

These rules are specified one per file under `specs/deploy/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- DEP-01 deploy: a throwaway container holding the forwarded agent: @../../specs/deploy/001-throwaway-deploy-container.md
- DEP-02 deploy connects over ssh carried by engine exec: @../../specs/deploy/002-deploy-ssh-transport.md
- DEP-03 deploy egress: allowed_hosts + deploy_hosts on its own network: @../../specs/deploy/003-deploy-egress.md
- DEP-04 deploy reads git and ssh settings from host-side files only: @../../specs/deploy/004-deploy-host-files.md
- DEP-05 deploy keeps state in its own volume, created on first use: @../../specs/deploy/005-deploy-state-volume.md
