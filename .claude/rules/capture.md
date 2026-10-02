---
paths:
  - "nixenv.sh"
---

# Capture rules (mitmproxy traffic capture behind squid)

These rules are specified one per file under `specs/capture/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- CAP-01 mitmproxy runs behind squid, never instead of it: @../../specs/capture/001-behind-squid.md
- CAP-02 Ingress capture routed by Caddy through mitmproxy: @../../specs/capture/002-ingress-capture.md
- CAP-03 Capture addon: tagging, storage, rebinding, streaming: @../../specs/capture/003-addon-safety.md
- CAP-04 mitmweb UI only through Caddy, with a token: @../../specs/capture/004-capture-ui.md
- CAP-05 Capture CA trust is explicit and sticky until untrust: @../../specs/capture/005-capture-ca-trust.md
