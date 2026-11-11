#!/usr/bin/env bats
# Sibling target repos (v0.13.0): repos checked out BESIDE the primary under target/, each a single repo of its
# own with its own trunk, gates and promotions (spec 2026-11-11, plan v0130). The fixture helper `add_sibling`
# lives beside `add_nested` in fixtures/leases/setup.bash.
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() { lease_fixture; LL="$DAEDALUS_HOME/core/leaselib.py"; }

lib() { ( cd "$DAEDALUS_HOME" && source core/lib.sh && "$@" ); }

@test "add_sibling: a clone beside the primary on its trunk, its bare origin with origin/HEAD, target.siblings and gates_<name> in config" {
  add_sibling portico
  [ -d "$DAEDALUS_HOME/target/portico/.git" ]
  [ ! -e "$DAEDALUS_HOME/target/thing/portico" ]
  [ "$(git -C "$DAEDALUS_HOME/target/portico" branch --show-current)" = main ]
  [ "$(git -C "$DAEDALUS_HOME/target/portico" symbolic-ref --short refs/remotes/origin/HEAD)" = origin/main ]
  run lib cfg_pairs target.siblings
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "portico	$BATS_TEST_TMPDIR/portico-origin.git" ]
  run lib cfg_list gates_portico
  [ "${lines[0]}" = "true" ]
  # the primary's own config is untouched
  run lib cfg_pairs target.nested
  [ "${lines[0]}" = "sub	https://example.com/sub.git" ]
}

@test "add_sibling NO_GATES=1: the sibling has no gates_<name> list" {
  NO_GATES=1 add_sibling portico
  run lib cfg_list gates_portico
  [ -z "$output" ]
}
