---
id: CAP-03
title: "Capture addon: tagging, storage, rebinding, streaming"
area: capture
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/capture_addon_test.py
  - tests/unit/37-capture.sh
---

# CAP-03: Capture addon: tagging, storage, rebinding, streaming

## Rule

- The addon tags flows (`flow.comment` = "<p> <dir>"), appends
  `captures/<p>.flows` and a one-line `<p>.log` with umask 077.
- It re-resolves egress names and refuses ANY non-global answer, pinning the
  checked IP.
- It never buffers `text/event-stream`.

## Why

Captures hold tokens and cookies. DNS can rebind between squid's lookup and
mitmproxy's. Buffering an event stream breaks streaming clients.

## How

Tested against a stub mitmproxy in `tests/capture_addon_test.py`.
