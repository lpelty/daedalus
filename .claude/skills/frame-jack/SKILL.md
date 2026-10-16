---
name: frame-jack
description: Switch the AMI (Artificial Machine Intelligence, the small local decision model) on or off, or read its status. Use when the operator says "frame-jack on", "frame-jack off", "frame-jack status" or "/frame-jack", or asks whether the AMI is running.
user-invocable: true
---

# frame-jack

The AMI is a small local decision model that answers yes/no questions about what the
agent is about to do. This skill is its switch. It holds no logic of its own: the
switch, the daemon and every check live in `core/frame-jack.py`.

## Run it

Take the operator's word — `on`, `off` or `status`; no word means `status` — and run,
from the deployment root:

```bash
python3 core/frame-jack.py <word>
```

Repeat the output word for word. It is written for the operator: one fact per line, a
refusal says what to fix and nothing was changed.

For `on`, add one sentence: the daemon takes about half a minute to answer its first
question, and the band above the prompt shows when it does.

## Do not

- Do not flip the switch any other way. The command above is the whole mechanism; the
  files it writes are its record and are not yours to edit.
- Do not run `on` or `off` unless the operator's own message in this session said
  `frame-jack on` (or `off`); the guard refuses it otherwise. When they ask in other words
  ("turn the AMI on"), ask them to type `/frame-jack on`.
