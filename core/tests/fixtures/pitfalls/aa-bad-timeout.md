---
type: pitfall
date: 2026-01-01
applies-to:
  bash:
    - '(?<![-\w./])timeout\s+(?:-\S+\s+)*(?:\d|\$)'
enforce: warn
---
# The timeout command is absent on this platform

Use a background process plus a polling loop instead.

**Evidence:** `which timeout` returns non-zero.
