---
type: pitfall
date: 2026-01-01
applies-to:
  path:
    - 'this-is-a-very-long-dashed-directory-segment-number-one-repeated-again-and-again/this-is-a-very-long-dashed-directory-segment-number-two-repeated-again-and-again/**/*.bats'
enforce: block
---
# Deep dashed directories under this tree are off limits

The path glob above translates to a regex over 200 characters; it must still
match and still block.
