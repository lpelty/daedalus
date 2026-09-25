#!/usr/bin/env bash
# Run the target harness's gate commands and produce the evidence record.
# Green is an exit code; the record is what a claim cites.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e
set -uo pipefail

# The gate definition must live inside this deployment. A config elsewhere
# is a gate the operator did not write.
home_real="$(cd "$DAEDALUS_HOME" && pwd -P)"
cfg_real="$(cd "$(dirname "$DAEDALUS_CONFIG")" 2>/dev/null && pwd -P)/$(basename "$DAEDALUS_CONFIG")"
case "$cfg_real" in
  "$home_real"/*) : ;;
  *) die "config $DAEDALUS_CONFIG resolves outside $DAEDALUS_HOME — refusing" ;;
esac

target="$(target_path)"
[ -d "$target" ] || die "no target checkout at $target — run core/sync-target.sh"

# Validation first, side effects after: everything below this point can die
# without having created a run directory, written fingerprint.err, or
# touched the manifest — an early-die evidence tree with nothing to point a
# BLOCKED claim at, which the boundary check then flags as unmanifested with
# no remedy. So both checks that can `die` run BEFORE any evidence
# directory, fingerprint, or run-id exists.

# The evidence row format below is tab-delimited. A literal tab inside a gate
# command would silently corrupt that format — line.split("\t", 4) absorbs the
# extra field into the wrong column instead of erroring. config.yaml is
# operator-authored, so a tab in a gate command is an error, not a use case:
# refuse loudly, upfront, before any gate runs or any evidence is recorded.
while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  case "$gate" in
    *"$(printf '\t')"*) die "config gates: gate command contains a tab character — refusing (the evidence row format is tab-delimited): $gate" ;;
  esac
done <<EOF
$(cfg_list gates)
EOF

# Zero-gates refusal, also moved ahead of any evidence-directory creation —
# counted directly off cfg_list's output rather than the gate-count computed
# during the run loop below, since that loop hasn't executed yet at this point.
gate_list_count="$(cfg_list gates | grep -c .)" || gate_list_count=0
[ "$gate_list_count" -gt 0 ] || die "no gates configured — refusing to report success (check the gates: list in config.yaml)"

# The refuter is ON unless the operator says otherwise, in writing. An
# unset verify.refute means true. `verify.refute: false` is honored only
# with a non-empty verify.refute_off_reason beside it — an off-switch with
# no reason is indistinguishable from an off-switch nobody meant to leave
# on, and a green run nobody reviewed is this repo's founding pitfall.
# Anything else is a typo, refused. All of it before a run-id exists.
refute_on=1
refute_cfg="$(cfg verify.refute 2>/dev/null || true)"
case "$refute_cfg" in
  ""|true) refute_on=1 ;;
  false)
    refute_off_reason="$(cfg verify.refute_off_reason 2>/dev/null || true)"
    if [ -z "$refute_off_reason" ]; then
      die "config verify.refute is false but verify.refute_off_reason is empty — the refuter runs after every PASS unless you say, in verify.refute_off_reason, why it should not; refusing before any gate runs"
    fi
    refute_on=0
    ;;
  *) die "config verify.refute must be true or false (got: $refute_cfg) — refusing before any gate runs" ;;
esac

# The refuter's timeout is operator config too. Discovered late — inside
# refute.sh, after every gate has run — a typo there records a FAIL run.json
# and vault summary that read, in the evidence, exactly like a real
# refutation. Refuse it here, with the other config errors, before a run-id
# exists. refute.sh re-checks (belt to this brace) but should never be the
# one to find it. An ABSENT verify.refute_timeout is fine: lib.sh
# refute_timeout defaults it to 600 seconds, so default-on needs no
# timeout line in config.yaml.
if [ "$refute_on" -eq 1 ]; then
  refute_timeout >/dev/null || die "config verify.refute_timeout is invalid — refusing before any gate runs"
fi

run_id="$(date +%Y%m%d-%H%M%S)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
ev_state="$DAEDALUS_HOME/state/evidence/$run_id"
ev_vault="$DAEDALUS_HOME/vault/evidence"
mkdir -p "$ev_state" "$ev_vault" || die "cannot create evidence directories"
manifest="$ev_vault/.manifest"

fingerprint() {
  if [ -f "$DAEDALUS_HOME/core/fingerprint.sh" ]; then
    bash "$DAEDALUS_HOME/core/fingerprint.sh" 2>"$ev_state/fingerprint.err" || printf 'null\n'
  else
    printf 'null\n'
  fi
}

started="$(date +%Y-%m-%dT%H:%M:%S)"
config_sha="$(shasum -a 256 "$DAEDALUS_CONFIG" | awk '{print $1}')"
fp_before="$(fingerprint)"
fp_secs="$(sed -n 's/^fingerprint_secs=//p' "$ev_state/fingerprint.err" 2>/dev/null | tail -1)"
[ -n "$fp_secs" ] || fp_secs=0

failed=0
gate_count=0
rows=""
while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  gate_count=$((gate_count + 1))
  log_file="$ev_state/gate-$gate_count.log"
  t0=$(date +%s)
  # Operator-authored config, deliberately trusted — eval is intentional.
  # stdin from /dev/null so a gate that reads stdin cannot eat the list.
  ( cd "$target" && eval "$gate" ) </dev/null >"$log_file" 2>&1
  code=$?
  dur=$(( $(date +%s) - t0 ))
  if [ "$code" -eq 0 ]; then
    log "PASS  $gate"
  else
    log "FAIL  $gate"
    failed=1
    fail_log="$log_file"
  fi
  rows="$rows
$gate_count	$code	$dur	$log_file	$gate"
done <<EOF
$(cfg_list gates)
EOF

fp_after="$(fingerprint)"
result=PASS
[ "$failed" -ne 0 ] && result=FAIL
if [ "$fp_before" = "null" ] || [ "$fp_after" = "null" ] || [ "$fp_before" != "$fp_after" ]; then
  result=INVALID
fi

# The evidence summary — no output excerpt; the vault is a pushed
# repository. Written FIRST to a temp file outside the evidence tree, and
# copied into the vault only after the refuter has spoken, with the final
# result. The vault copy used to be written here, before the refute call,
# with `result: PASS`, and its manifest line only at the end: for the whole
# length of an opus review (up to verify.refute_timeout) a PASS-labelled
# evidence file sat under vault/evidence/** with no manifest line and no
# run.json — and a review killed from outside (a Bash tool timeout is
# 120 s by default) left it there for good, under a protected path Daedalus
# cannot remove: exactly the unmanifested evidence with no remedy that the
# validation-first rule above exists to prevent. refute.sh reads the
# summary from the path passed as its third argument.
write_summary() {   # write_summary <path> <result>
  {
    printf -- '---\ntype: evidence\nrun-id: %s\nresult: %s\nfingerprint: %s\nconfig-sha: %s\ncreated: %s\n---\n' \
      "$run_id" "$2" "$fp_before" "$config_sha" "$started"
    printf '# Gate run %s — %s\n\n| # | command | exit | seconds | log |\n|---|---|---|---|---|\n' "$run_id" "$2"
    printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r n code dur logf cmd; do
      [ -n "$n" ] || continue
      printf '| %s | `%s` | %s | %s | `%s` |\n' "$n" "$cmd" "$code" "$dur" "$logf"
    done
  } > "$1"
}
summary_tmp="$(mktemp)" || die "cannot create a temp file for the evidence summary"
write_summary "$summary_tmp" "$result"

# Everything under the run directory that is complete at this point goes
# into the manifest BEFORE the refuter runs: the gate logs and the
# fingerprint error file are what they are, verdict or no verdict. If the
# review is killed from outside, what is left behind is manifested and
# carries no result at all — run.json and the vault summary come after.
{
  [ -f "$ev_state/fingerprint.err" ] && printf '%s\n' "$ev_state/fingerprint.err"
  printf '%s\n' "$rows" | awk -F'\t' 'NF {print $4}'
} >> "$manifest"

if [ "$result" = PASS ] && [ "$refute_on" -eq 1 ]; then
  refute_msg="$(bash "$DAEDALUS_HOME/core/refute.sh" "$run_id" "${GATES_CRITERIA:-}" "$summary_tmp" 2>&1 >/dev/null)"
  refute_code=$?
  if [ "$refute_code" -ne 0 ]; then
    result=FAIL; failed=1
    if [ "$refute_code" -eq 1 ]; then
      # Exit 1 = REFUTED; the review file is the fail_log.
      fail_log="$ev_vault/$run_id-review.md"
    else
      # Exit 2 = the refuter could not certify: CLI missing, python3 missing,
      # CLI failed or timed out and was killed (no review file was written),
      # nothing to review, or a reply with no VERDICT line (review file
      # exists; the refuter's message carries its path). Any other code =
      # refute.sh itself died — a signal, a die — and there is no verdict
      # either. Only 0 is STANDS; an allow-list of failure codes once let
      # 143 stay PASS. Either way the refuter's own message is the honest
      # fail_log.
      log "refute: $refute_msg"
      fail_log="$refute_msg"
    fi
  fi
fi

# The vault summary, with the verdict folded into `result`, so this file and
# run.json never disagree — a re-setup deployment's state-loss fallback reads
# this frontmatter verbatim, so a stale PASS here would be a real false claim.
write_summary "$ev_vault/$run_id.md" "$result"
rm -f "$summary_tmp"

# run.json — through python for correct JSON escaping of arbitrary commands.
# The row data is written to a temp file OUTSIDE the evidence tree (so it
# never needs a manifest line) and its path passed via argv, not piped on
# stdin: `python3 -` already consumes stdin as the program source (the
# heredoc), so a second use of stdin for data is silently empty. Written
# after the refute call so a REFUTED verdict's flipped `result` is what gets
# recorded here.
rows_tmp="$(mktemp)" || die "cannot create a temp file for gate rows"
printf '%s' "$rows" > "$rows_tmp"
python3 - "$ev_state/run.json" "$run_id" "$started" "$fp_before" "$fp_secs" "$config_sha" "$result" "$rows_tmp" <<'PY'
import json, sys, time
out, run_id, started, fp, fp_secs, config_sha, result, rows_path = sys.argv[1:9]
gates = []
with open(rows_path) as fh:
    data = fh.read()
for line in data.splitlines():
    if not line.strip():
        continue
    n, code, dur, log, cmd = line.split("\t", 4)
    gates.append({"n": int(n), "command": cmd, "exit": int(code), "duration_s": int(dur), "log": log})
rec = {"run_id": run_id, "started": started, "fingerprint": fp, "fingerprint_secs": int(fp_secs or 0),
       "config_sha": config_sha, "gates": gates, "result": result}
rec["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S")
with open(out, "w") as fh:
    json.dump(rec, fh, indent=2)
PY
rm -f "$rows_tmp"

printf '%s\n' "$ev_state/run.json" "$ev_vault/$run_id.md" >> "$manifest"

if [ "$failed" -ne 0 ]; then
  log "run-id: $run_id"
  log "log: $fail_log"
  die "one or more gates failed"
fi
if [ "$result" = INVALID ]; then
  log "run INVALID — do not cite"
else
  log "all gates passed ($result)"
  printf '%s\n' "$run_id"
fi
