---
type: pitfall
date: 2026-01-01
applies-to:
  path:
    - '**/*.bats'
enforce: warn
---
# A non-final double-bracket assertion is silently ignored

Use a single-bracket test for any assertion that is not the last statement.
