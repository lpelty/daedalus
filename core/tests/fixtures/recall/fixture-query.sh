#!/bin/bash
# Test engine: report argv arity, $1, and the store env to $FIXTURE_REPORT;
# results (from $FIXTURE_RESULTS) on stdout.
{
  printf 'argc=%s\n' "$#"
  printf 'arg1=%s\n' "$1"
  printf 'store=%s\n' "$DAEDALUS_RECALL_STORE"
} >> "$FIXTURE_REPORT"
cat "$FIXTURE_RESULTS"
