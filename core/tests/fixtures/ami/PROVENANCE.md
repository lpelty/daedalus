# Provenance of the AMI fixture items

`items.jsonl`, `state-destructive.txt` and `state-suite.txt` are two items from the frame-jack
calibration dataset (the lab's `calibration/dataset.jsonl`, measured 2026-10-15) and the state text
the lab's own builder (`calibration/score.py`, `state_destructive` / `state_suite`) produced for them.
`test_ami_hook.bats` pins `amilib.state_destructive` / `state_suite` equal to these texts **after
substituting the home and the scratchpad** — a weaker claim than byte-equality with the lab, by design
(spec §5.5): the pin proves the builder was ported, not that a deployment's state matches the lab's.

| Item | `tool_use_id` | Kind |
|---|---|---|
| `destructive:3ff430e6:101` | `toolu_01HJNCNWxAnKw8nydSaW1Avf` | destructive — a `cd … && ls && cat` in the vault |
| `suite:4ad0b99a:5752` | `toolu_01GMcJbm2mt4DWNBuZE4s86C` | suite — an evidence run after a `pytest` run, three files edited since |

## Substitutions (applied to the item and to its state text alike, 2026-10-15)

1. The Daedalus home as the calibration machine had it → `<HOME>`. The test replaces it with the
   fixture home (resolved with `pwd -P`).
2. That home's Claude Code scratchpad, `/private/tmp/claude-<uid>/<slug of the home>` (no trailing
   slash; the worktree line adds it) → `<SCRATCH>`. The test replaces it with `amilib.scratchpad(root)`.
3. The worktree line's last sentence named the live checkout of the calibration deployment's target
   repository by its absolute path — a path outside the home that the identity scan rejects and that
   no deployment can know without reading config. `amilib.worktree_line` renders that clause as
   "The live checkout of the target repository outside this home, the rest of the home directory,
   and any git remote are outside it." and the stored text carries the same wording. (A fixed
   rewording, not a substitution: the test makes no replacement for it.)
4. The calibration deployment's target-repository name (a word the identity scan rejects) → `thing`,
   the fixture target's name, wherever it appeared (the `cwd`, the previous suite-run command, one
   previous tool call).
5. The `session_file` field (a transcript path under the operator's home, never read by the state
   builders) is dropped.

Everything else — the commands, descriptions, operator messages, previous tool calls, the edited
files, the tool-call counts — is as the dataset had it.

## Regenerate

From the lab (which holds the literal paths; this file may not):
`.venv/bin/python scripts/make_fixture_items.py --out <worktree>/core/tests/fixtures/ami`.
The script refuses to write if any token of the identity scan survives the substitutions.
