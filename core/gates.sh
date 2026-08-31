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

if [ "$gate_count" -eq 0 ]; then
  die "no gates configured — refusing to report success (check the gates: list in config.yaml)"
fi

fp_after="$(fingerprint)"
result=PASS
[ "$failed" -ne 0 ] && result=FAIL
if [ "$fp_before" = "null" ] || [ "$fp_after" = "null" ] || [ "$fp_before" != "$fp_after" ]; then
  result=INVALID
fi

# run.json — through python for correct JSON escaping of arbitrary commands.
# The row data is written to a temp file OUTSIDE the evidence tree (so it
# never needs a manifest line) and its path passed via argv, not piped on
# stdin: `python3 -` already consumes stdin as the program source (the
# heredoc), so a second use of stdin for data is silently empty.
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

# Vault summary — no output excerpt; the vault is a pushed repository.
{
  printf -- '---\ntype: evidence\nrun-id: %s\nresult: %s\nfingerprint: %s\nconfig-sha: %s\ncreated: %s\n---\n' \
    "$run_id" "$result" "$fp_before" "$config_sha" "$started"
  printf '# Gate run %s — %s\n\n| # | command | exit | seconds | log |\n|---|---|---|---|---|\n' "$run_id" "$result"
  printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r n code dur logf cmd; do
    [ -n "$n" ] || continue
    printf '| %s | `%s` | %s | %s | `%s` |\n' "$n" "$cmd" "$code" "$dur" "$logf"
  done
} > "$ev_vault/$run_id.md"

{
  printf '%s\n' "$ev_state/run.json" "$ev_vault/$run_id.md"
  [ -f "$ev_state/fingerprint.err" ] && printf '%s\n' "$ev_state/fingerprint.err"
  printf '%s\n' "$rows" | awk -F'\t' 'NF {print $4}'
} >> "$manifest"

if [ "$failed" -ne 0 ]; then
  log "run-id: $run_id"
  log "log: $fail_log"
  die "one or more gates failed"
fi
log "all gates passed ($result)"
printf '%s\n' "$run_id"
