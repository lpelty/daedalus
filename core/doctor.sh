#!/usr/bin/env bash
# Verify this deployment is wired correctly. Exits 0 only when it is.
#
# Names every missing piece rather than aborting on the first — an operator
# standing up a deployment should learn everything that is wrong in one run.
# Like gates.sh, this survives individual check failures instead of using
# -e, because it must keep going after a failed check to report the rest.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# AFTER the source, not before: lib.sh runs `set -euo pipefail`, so setting
# this first had errexit switched straight back on underneath us. Every check
# that returned non-zero then aborted the run instead of being counted, which
# is the opposite of the contract stated above.
set +e
set -uo pipefail

problems=0
note_problem() { log "MISSING  $*"; problems=$((problems + 1)); }

[ -f "$DAEDALUS_CONFIG" ] || { log "MISSING  config.yaml (copy config.example.yaml)"; exit 1; }

# The release (spec §14, §15): VERSION's one line. A checkout without it
# predates v0.7.0 — the upgrade has nothing to upgrade to — or is damaged.
if ver="$(daedalus_version)"; then
  log "OK       version: $ver"
else
  note_problem "VERSION — this checkout predates v0.7.0 (pull the release) or is corrupt"
fi

target_repo_ok=0
for key in target.repo target.branch vault.repo proposals.budget; do
  if cfg "$key" >/dev/null 2>&1; then
    log "OK       config: $key"
    [ "$key" = "target.repo" ] && target_repo_ok=1
  else
    note_problem "config: $key"
  fi
done

if [ -n "$(cfg_list gates)" ]; then
  log "OK       config: gates ($(cfg_list gates | wc -l | tr -d ' ') defined)"
else
  note_problem "config: gates (at least one required)"
fi
if [ -n "$(cfg_list gates_setup)" ]; then
  log "OK       config: gates_setup ($(cfg_list gates_setup | wc -l | tr -d ' ') step(s) run before the gates)"
fi

# target_path() dies (hard exit) if target.repo is unset. Only call it once
# we've confirmed the key is actually present above — otherwise it would
# abort this script before the vault checks below ever run, silently
# skipping checks instead of naming them as MISSING like everything else.
if [ "$target_repo_ok" -eq 1 ]; then
  # target_path also `die`s when it REJECTS the config — a target.dir carrying
  # a path separator, for instance. Discarding that message with `|| true`
  # turned a config error into the generic "run core/sync-target.sh", pointing
  # the operator at a remedy that cannot possibly help: sync-target calls this
  # same function and hits the same rejection. Keep stderr so the real cause
  # can be reported, and keep going — doctor names every problem in one run.
  #
  # The exit code decides, not whether stderr is empty: with lease files
  # present, target_path resolves through leaselib.py, which prints an exit-0
  # courtesy note for an operator shell ("no session — using the prime's
  # checkout (N windows live)"). Reading that note as a rejection turned every
  # doctor run from a shell red the moment a window was open. Exit-0 stderr is
  # dropped, not echoed: that note counts every unreleased lease, while the
  # leases line below counts by liveness, and printing both put "2 windows
  # live" and "1 window live, 1 stale" three lines apart in one run. The
  # leases line is the one count; an unreadable lease file, the note's other
  # content, is already a MISSING line there.
  target_err="$(target_path 2>&1 >/dev/null)"; target_rc=$?
  target="$(target_path 2>/dev/null || true)"
  if [ "$target_rc" -ne 0 ]; then
    target_err="${target_err#daedalus: }"
    note_problem "${target_err:-target checkout — cannot resolve the target path (target_path exited $target_rc)}"
  elif [ -z "$target" ] || [ ! -d "$target" ]; then
    note_problem "target checkout — run core/sync-target.sh"
  elif ! is_work_tree_root "$target"; then
    # The same predicate fingerprint.sh and sync-target.sh use (lib.sh), so
    # doctor and the fingerprint never disagree: a linked worktree's .git is
    # a file (`-d .git` called it broken), and a target that lost its .git
    # inside an outer repository is broken even though git answers there.
    note_problem "target checkout is not a git repo: $target — run core/sync-target.sh"
  else
    log "OK       target checkout: $target"
    # The trunk name. Every branch-aware guard (guard-bash's push/commit
    # deny, the promotion gate) reads config target.branch; a config that
    # names a branch the target does not use leaves all of them inert while
    # reporting themselves fine — one deployment ran with `main`
    # configured against a GitLab trunk called `mainline`. The hard test
    # is existence: a configured branch that origin does not have is a
    # MISSING (sync-target.sh cannot even fetch it). A branch that exists
    # but is not the remote's default (refs/remotes/origin/HEAD, recorded
    # by `git clone`) is a NOTE naming both, never a problem: a deployment
    # may deliberately guard a trunk that is not the remote's default, and
    # setup.sh dies on a red doctor — prescribing "change to the default"
    # there would re-inert every branch guard. No network: `git remote show
    # origin` would answer when origin/HEAD is unset, but it contacts the
    # remote, so an unset origin/HEAD is reported as undeterminable rather
    # than guessed. (An unset target.branch is already MISSING above.)
    configured_branch="$(cfg target.branch 2>/dev/null || true)"
    if [ -n "$configured_branch" ]; then
      remote_default="$(git -C "$target" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      remote_default="${remote_default#origin/}"
      if [ -z "$(git -C "$target" for-each-ref --count=1 refs/remotes/origin/ 2>/dev/null)" ]; then
        # No remote-tracking refs at all (a checkout with no origin, or one
        # that is not a git repo git can read): absence proves nothing.
        log "NOTE     target.branch: cannot tell whether $configured_branch exists at origin (no origin refs are recorded in $target), so config.yaml's target.branch is unchecked"
      elif ! git -C "$target" rev-parse --verify -q "refs/remotes/origin/$configured_branch" >/dev/null 2>&1; then
        if [ -n "$remote_default" ]; then
          note_problem "config.yaml says target.branch: $configured_branch but origin has no branch by that name (its default branch is $remote_default); fix target.branch in config.yaml"
        else
          note_problem "config.yaml says target.branch: $configured_branch but origin has no branch by that name; fix target.branch in config.yaml"
        fi
      elif [ -z "$remote_default" ]; then
        log "NOTE     target.branch: $configured_branch exists at origin; cannot tell whether it is the target's default branch (origin/HEAD is not recorded in $target)"
      elif [ "$remote_default" = "$configured_branch" ]; then
        log "OK       target.branch: $configured_branch is the target's default branch"
      else
        log "NOTE     target.branch: $configured_branch exists at origin but is not its default branch ($remote_default) — confirm this is the trunk you mean to guard; the branch guard denies pushes and commits to $remote_default as well"
      fi
    fi
  fi
else
  note_problem "target checkout — cannot determine path without config: target.repo"
fi

# Leases (spec §15). Every line is plain language: "03 (electron; no live
# session since 09:40)", never a bare token. The counting and the staleness
# call live in leaselib.py (doctor-lines) so doctor and the board can never
# disagree; it decides each line's kind and this block counts the MISSING
# ones. Guarded on leaselib.py existing so a fixture without it skips the
# block, visibly. Skipped when state/leases/ is absent: leaselib takes its
# lock inside that directory and would create it as a side effect of a
# diagnostic. The here-string loop keeps note_problem in this shell — a pipe
# would put it in a subshell and lose the count (see the unverified-claims
# block below).
if [ -f "$DAEDALUS_HOME/core/leaselib.py" ]; then
  for d in state/leases worktrees state/promote state/direct-calls; do
    if [ ! -d "$DAEDALUS_HOME/$d" ]; then
      note_problem "$d/ — start a session (the upgrade runs at SessionStart) or run core/setup.sh"
    fi
  done
  if [ -d "$DAEDALUS_HOME/state/leases" ]; then
    lease_out="$(python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-lines 2>/dev/null)"
    lease_rc=$?
    if [ "$lease_rc" -ne 0 ]; then
      note_problem "leases: check failed (core/leaselib.py doctor-lines exited $lease_rc)"
    else
      while IFS= read -r line; do
        case "$line" in
          "") ;;
          "MISSING  "*) note_problem "${line#MISSING  }" ;;
          *) log "$line" ;;
        esac
      done <<EOF
$lease_out
EOF
    fi
  fi
  # From a session, the registry line names what the registry says this session is
  # (kind and entrypoint — §4.8's interactive-window test); from a shell, it counts entries.
  registry="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  sess_kind=""
  if [ -d "$registry" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    sess_kind="$(python3 "$DAEDALUS_HOME/core/leaselib.py" registry-kind "$CLAUDE_CODE_SESSION_ID" 2>/dev/null)"
  fi
  if [ -n "$sess_kind" ]; then
    log "OK       session registry: this session is $sess_kind"
  elif [ -d "$registry" ]; then
    n="$(ls "$registry"/*.json 2>/dev/null | wc -l | tr -d ' ')"
    log "OK       session registry: $registry/ present ($n entries)"
  else
    log "NOTE     session registry absent — liveness by heartbeat only on this build; peer names unknown; no window numbers itself and nobody takes the pen at start (launch each window with DAEDALUS_LEASE=<NN>; core/lease.sh prime take gives one the pen)"
  fi
  # The registry's shape (lease-board spec §5): whether this home's live window
  # entries still carry the fields leaselib.py reads (pid, sessionId, startedAt,
  # procStart, kind, entrypoint, name) and procStart still parses. The registry
  # is undocumented and changed meaning on 2026-10-10 with nothing here saying
  # so. NOTE, never MISSING: liveness has a fallback for every field. Runs
  # whether or not state/leases/ exists (the command takes no lock when the
  # directory is absent, so it never creates it).
  reg_out="$(python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-registry 2>/dev/null)"
  reg_rc=$?
  if [ "$reg_rc" -ne 0 ]; then
    log "NOTE     registry shape: check failed (core/leaselib.py doctor-registry exited $reg_rc)"
  else
    while IFS= read -r line; do
      [ -n "$line" ] && log "$line"
    done <<EOF
$reg_out
EOF
  fi
  # The lease board on screen (lease-board spec §5.3): the band above the prompt is a mod each
  # deployment installs once, at local scope, so the absolute path lands in the gitignored
  # .claude/settings.local.json. NOTE, never MISSING: the deployment works without the band, and
  # the model-facing board is unchanged. Judged by a JSON read of that file and of the user-scope
  # settings (~/.claude/settings.json: `claude plugin install` without --scope installs there, install
  # page "user scope by default"; local beats user, plugin loading reference "Find where a plugin is
  # enabled"), as local_capture_wiring does below; a file that is not JSON reads as not written
  # (review 2026-10-11, finding 14). The line names the file that decided.
  board_state="$(python3 - "$DAEDALUS_HOME/.claude/settings.local.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" <<'PY' 2>/dev/null || true
import json, sys
for path, label in ((sys.argv[1], ".claude/settings.local.json"), (sys.argv[2], sys.argv[2])):
    try:
        d = json.load(open(path))
    except (OSError, ValueError):
        continue
    v = (d.get("enabledPlugins") or {}).get("lease-board@daedalus-mods") if isinstance(d, dict) else None
    if v is True:
        print("enabled " + label); break
    if v is False:
        print("disabled " + label); break
PY
)"
  case "$board_state" in
    "enabled "*) log "OK       lease board on screen: lease-board@daedalus-mods is enabled in ${board_state#enabled }" ;;
    "disabled .claude/settings.local.json") log "NOTE     lease board on screen: lease-board@daedalus-mods is disabled in .claude/settings.local.json — \`claude plugin enable lease-board@daedalus-mods --scope local\` turns it back on" ;;
    "disabled "*) log "NOTE     lease board on screen: lease-board@daedalus-mods is disabled in ${board_state#disabled } — \`claude plugin enable lease-board@daedalus-mods\` turns it back on" ;;
    *) log "NOTE     lease board on screen: not installed for this deployment — run \`claude plugin marketplace add ./mods --scope local\` then \`claude plugin install lease-board@daedalus-mods --scope local\` in the Daedalus home, then open a new terminal" ;;
  esac
  # One machine holds one marketplace record per name ("There is one known_marketplaces.json per
  # user, so a marketplace you add in one project is available in every project", plugin loading
  # reference; a repeat `marketplace add` prints "already on disk" and exits 0, CLI reference), so a
  # second Daedalus checkout on the machine loads the FIRST checkout's mods/. The record lives under
  # the plugins root, ~/.claude/plugins unless CLAUDE_CODE_PLUGIN_CACHE_DIR is set (loading reference,
  # "Find plugins on disk"); whether CLAUDE_CONFIG_DIR moves it is not documented, so it is not read
  # here. NOTE when the record names another path (review 2026-10-11, findings 12 and 18).
  other_mods="$(python3 - "${CLAUDE_CODE_PLUGIN_CACHE_DIR:-$HOME/.claude/plugins}/known_marketplaces.json" "$DAEDALUS_HOME/mods" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    d = json.load(open(sys.argv[1]))
    rec = d.get("daedalus-mods") if isinstance(d, dict) else None
except (OSError, ValueError):
    rec = None
if isinstance(rec, dict):
    path = (rec.get("source") or {}).get("path") if isinstance(rec.get("source"), dict) else None
    path = path or rec.get("installLocation")
    if isinstance(path, str) and path and os.path.realpath(path) != os.path.realpath(sys.argv[2]):
        print(path)
PY
)"
  [ -z "$other_mods" ] || log "NOTE     lease board on screen: this machine's daedalus-mods marketplace points at $other_mods, not $DAEDALUS_HOME/mods — one machine holds one record of that name, so a window here would load the other checkout's board; remove it there (\`claude plugin marketplace remove daedalus-mods\`) before installing here"
  # Mods need Claude Code 2.1.287 or later in the terminal (mods overview). The version is the first
  # word of `claude --version` ("2.1.296 (Claude Code)"); compared as numbers, not as text.
  if command -v claude >/dev/null 2>&1; then
    claude_ver="$(claude --version 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -n "$claude_ver" ] && ! python3 -c 'import sys
try:
    a = [int(x) for x in sys.argv[1].split(".")[:3]]
except ValueError:
    sys.exit(0)
sys.exit(0 if a >= [2, 1, 287] else 1)' "$claude_ver"; then
      log "NOTE     lease board on screen: claude $claude_ver is older than 2.1.287, which mods need — update Claude Code"
    fi
  else
    log "NOTE     lease board on screen: claude is not on PATH here, so its version was not checked (mods need 2.1.287 or later)"
  fi
  for old in pitfall-seen.json code-context-seen.json; do
    [ -f "$DAEDALUS_HOME/state/$old" ] && log "NOTE     state/$old is the pre-v0.7.0 shared file — the upgrade removes it at the next session start"
  done
fi

# The upgrade (spec §14, §15): the stamp, what in target/ it would still move, hot.md's
# field. One reader, core/upgrade.py --doctor — local refs only, it never fetches; the
# here-string loop keeps the MISSING count (see the leases block). Skipped when a
# fixture has no upgrade.py.
if [ -f "$DAEDALUS_HOME/core/upgrade.py" ]; then
  up_out="$(python3 "$DAEDALUS_HOME/core/upgrade.py" --doctor 2>/dev/null)"
  up_rc=$?
  if [ "$up_rc" -ne 0 ]; then
    note_problem "upgrade: check failed (core/upgrade.py --doctor exited $up_rc)"
  else
    while IFS= read -r line; do
      case "$line" in
        "") ;;
        "MISSING  "*) note_problem "${line#MISSING  }" ;;
        # a line to paste into config.yaml, printed bare so it can be copied as it is (critic finding 5)
        "PASTE    "*) printf '%s\n' "${line#PASTE    }" ;;
        *) log "$line" ;;
      esac
    done <<EOF
$up_out
EOF
  fi
fi

# Episodic capture (spec §4.7, §15). Optional, so an absent memory: block is a
# NOTE. A block memory_env cannot use is MISSING: the Stop tick exits 0 by
# design, so capture would be off, silently, on a deployment that asked for it.
# The block is judged alone — the capture variables of whoever runs doctor are
# cleared first, so an exported TENANT_BANK cannot hide a broken block.
local_settings="$DAEDALUS_HOME/.claude/settings.local.json"
# How settings.local.json still wires capture.py, judged one hook command at a
# time by walking the JSON: prints "wired" when some command runs capture.py,
# and "leftover" when such a command also carries a TENANT_* assignment, and
# "recall-leftover" when a recall-inject.py command carries one. A line
# grep over a one-line file matched a recall-inject.py TENANT_* prefix
# followed, later on the same line, by an unprefixed capture.py command.
local_capture_wiring() {
  [ -f "$local_settings" ] || return 0
  python3 - "$local_settings" <<'PY' 2>/dev/null || true
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(0)
hooks = d.get("hooks") if isinstance(d, dict) else None
cmds, recall = [], []
for groups in (hooks.values() if isinstance(hooks, dict) else []):
    for g in (groups if isinstance(groups, list) else []):
        for h in ((g.get("hooks") or []) if isinstance(g, dict) else []):
            c = h.get("command") if isinstance(h, dict) else None
            if isinstance(c, str) and "capture.py" in c:
                cmds.append(c)
            if isinstance(c, str) and "recall-inject.py" in c:
                recall.append(c)
out = []
if cmds:
    out.append("wired")
if any(re.search(r"(^|\s)TENANT_[A-Z_]*=", c) for c in cmds):
    out.append("leftover")
if any(re.search(r"(^|\s)TENANT_[A-Z_]*=", c) for c in recall):
    out.append("recall-leftover")
print(" ".join(out))
PY
}
local_capture="$(local_capture_wiring)"
if memory_configured; then
  mem_env="$( (unset $MEMORY_ENV_VARS; memory_env) 2>/dev/null )"
  if [ $? -ne 0 ]; then
    mem_err="$( (unset $MEMORY_ENV_VARS; memory_env) 2>&1 >/dev/null )"
    note_problem "memory: ${mem_err#daedalus: }"
  else
    mem_vals="$( (eval "$mem_env"; printf '%s\t%s\t%s' "$TENANT_BANK" "$CAPTURE_INTERVAL" "$TRANSCRIPT_DIR") )"
    mem_bank="$(printf '%s' "$mem_vals" | cut -f1)"
    mem_interval="$(printf '%s' "$mem_vals" | cut -f2)"
    mem_tdir="$(printf '%s' "$mem_vals" | cut -f3)"
    mem_usable=1
    log "OK       memory: bank $mem_bank, capture every $mem_interval s"
    if [ ! -d "$mem_tdir" ]; then
      log "NOTE     memory: transcript directory $mem_tdir does not exist — set memory.transcript_dir in config.yaml (a hook names its own transcript; this is the fallback core/close.sh uses)"
    fi
  fi
  # Each line judged alone (recall-inject.py reads the block too since v0.7.0).
  # The recall line is named only when the block is usable: against a block
  # recall cannot read, its prefixes are what keeps recall working.
  if case " $local_capture " in *" leftover "*) true ;; *) false ;; esac; then
    log "NOTE     .claude/settings.local.json still runs capture.py with TENANT_* on its hook line — the memory: block in config.yaml now carries them and the tracked SessionEnd hook flushes; that line can be removed"
  fi
  if [ "${mem_usable:-0}" = 1 ] && case " $local_capture " in *" recall-leftover "*) true ;; *) false ;; esac; then
    log "NOTE     .claude/settings.local.json still runs recall-inject.py with TENANT_* on its hook line — it reads the memory: block in config.yaml now; that line's prefixes can be removed"
  fi
elif case " $local_capture " in *" wired "*) true ;; *) false ;; esac; then
  log "NOTE     memory: block absent from config.yaml — Stop-cadence capture is off; a SessionEnd capture wired in .claude/settings.local.json still runs"
else
  log "NOTE     memory: block absent from config.yaml — episodic capture is off (optional; see \"Episodic memory capture\" in README.md)"
fi

# A healthy vault is either its own git repo (vault/.git exists — the
# original assumption), or a directory absorbed into the parent daedalus
# repo via `git subtree add` — a deliberate choice on some deployments when
# the vault holds session history on a single disk with no remote of its own.
# `git ls-files --error-unmatch` alone is not sufficient: it checks the
# INDEX, not the working tree, so it reports success even for a vault
# deleted from disk after being committed (verified empirically). The
# on-disk directory check guards against exactly that false green.
vault_tracked_by_parent=0
if [ -d "$DAEDALUS_HOME/vault" ] && git -C "$DAEDALUS_HOME" ls-files --error-unmatch vault >/dev/null 2>&1; then
  vault_tracked_by_parent=1
fi

if [ ! -d "$DAEDALUS_HOME/vault/.git" ] && [ "$vault_tracked_by_parent" -eq 0 ]; then
  note_problem "vault is not a git repo and is not tracked by the parent repo: $DAEDALUS_HOME/vault — run core/sync-vault.sh"
else
  for d in infrastructure specs plans proposals pitfalls exchange; do
    if [ -d "$DAEDALUS_HOME/vault/$d" ]; then
      log "OK       vault/$d"
    else
      note_problem "vault/$d — run core/sync-vault.sh"
    fi
  done
fi

# Pitfall triggers: a pitfall that cannot fire is a pitfall that will be
# missed again. Informational — never a problem — and skipped, visibly, when
# the script is absent (the doctor fixture copies only lib.sh and doctor.sh).
# stderr goes to /dev/null rather than being merged into the piped stream: a
# crashing --check must not print a raw Python traceback disguised as doctor
# NOTE lines. On a non-zero exit we report exactly one line naming the exit
# code instead.
if [ -f "$DAEDALUS_HOME/core/pitfall-inject.py" ]; then
  pitfall_out="$(python3 "$DAEDALUS_HOME/core/pitfall-inject.py" --check 2>/dev/null)"
  pitfall_status=$?
  if [ "$pitfall_status" -ne 0 ]; then
    log "NOTE     pitfalls: check failed (core/pitfall-inject.py --check exited $pitfall_status)"
  else
    printf '%s\n' "$pitfall_out" | while IFS= read -r line; do
      log "NOTE     $line"
    done
  fi
else
  log "NOTE     pitfalls: check skipped (core/pitfall-inject.py absent)"
fi

# Document recall: enhancement-layer health, NOTE lines only (spec §2.6).
if [ -f "$DAEDALUS_HOME/core/vault-search.py" ]; then
  recall_out="$(python3 "$DAEDALUS_HOME/core/vault-search.py" --check 2>/dev/null)"
  recall_status=$?
  if [ "$recall_status" -ne 0 ]; then
    log "NOTE     document recall: check failed (core/vault-search.py --check exited $recall_status)"
  else
    printf '%s\n' "$recall_out" | while IFS= read -r line; do
      log "NOTE     $line"
    done
  fi
else
  log "NOTE     document recall: check skipped (core/vault-search.py absent)"
fi

# Code context: enhancement-layer health, NOTE lines only (spec §3.3).
if [ -f "$DAEDALUS_HOME/core/code-context.py" ]; then
  cc_out="$(python3 "$DAEDALUS_HOME/core/code-context.py" --check 2>/dev/null)"
  cc_status=$?
  if [ "$cc_status" -ne 0 ]; then
    log "NOTE     code context: check failed (core/code-context.py --check exited $cc_status)"
  else
    printf '%s\n' "$cc_out" | while IFS= read -r line; do
      log "NOTE     $line"
    done
  fi
else
  log "NOTE     code context: check skipped (core/code-context.py absent)"
fi

# Direct calls (spec §8, §15): the direct_call: block, distribution-code
# integrity (the launcher and promote refuse while core/, CLAUDE.md or
# .claude/settings.json is modified) and receipts a launcher left active.
# One reader, core/call_agent.py --doctor, so doctor and the launcher never
# disagree about what is valid; it decides each line's kind and this block
# counts the MISSING ones (here-string, not a pipe: see the leases block).
# Skipped, visibly absent, when a fixture has no call_agent.py.
if [ -f "$DAEDALUS_HOME/core/call_agent.py" ]; then
  dc_out="$(python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor 2>/dev/null)"
  dc_rc=$?
  if [ "$dc_rc" -ne 0 ]; then
    note_problem "direct calls: check failed (core/call_agent.py --doctor exited $dc_rc)"
  else
    while IFS= read -r line; do
      case "$line" in
        "") ;;
        "MISSING  "*) note_problem "${line#MISSING  }" ;;
        *) log "$line" ;;
      esac
    done <<EOF
$dc_out
EOF
  fi
fi

# CLAUDE.md's deny rule and auto mode's classifyAllShell (agent-runnable design 2026-10-15, §4.6). Read-only.
# The distribution denies Edit(/CLAUDE.md) in the tracked settings; a deployment that chose to let Daedalus edit
# its own brief has removed it, and then auto mode's "Self-Modification" soft deny may still refuse the edit —
# the README says how that is cleared (a user-scope autoMode.allow entry: the classifier never reads autoMode
# from a project's .claude/settings*.json). Every permissions.deny Edit(...) rule of the project, local and
# user files is read; a rule covers CLAUDE.md when it names it under any anchor verifylib.home_relative_glob
# reads (/path, ./path, //<home>/path, bare path) — the line names the file that decided. A user-scope
# autoMode.classifyAllShell suspends every Bash allow rule in auto mode, the delete's (Bash(core/lease.sh
# release:*)) included, so the classifier is back in front of it. Managed settings are not read.
user_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
cm_state="$(python3 - "$DAEDALUS_HOME" "$user_settings" <<'PY' 2>/dev/null || true
import json, os, re, sys
sys.path.insert(0, os.path.join(sys.argv[1], "core"))
from pathlib import Path
import verifylib as v
root = Path(sys.argv[1])
files = ((root / ".claude" / "settings.json", ".claude/settings.json"),
         (root / ".claude" / "settings.local.json", ".claude/settings.local.json"),
         (Path(sys.argv[2]), sys.argv[2]))
covered = None
classify_all = False
for path, label in files:
    try:
        d = json.load(open(path))
    except (OSError, ValueError):
        continue
    if not isinstance(d, dict):
        continue
    if label == sys.argv[2] and (d.get("autoMode") or {}).get("classifyAllShell") is True:
        classify_all = True
    for rule in ((d.get("permissions") or {}).get("deny") or []):
        m = re.fullmatch(r"Edit\((.+)\)", str(rule))
        if not m:
            continue
        g = v.home_relative_glob(root, m.group(1))
        if g == "CLAUDE.md" and covered is None:
            covered = label
print("covered " + covered if covered else "uncovered")
print("classifyAllShell" if classify_all else "")
PY
)"
cm_first="$(printf '%s\n' "$cm_state" | sed -n 1p)"
case "$cm_first" in
  "covered "*) log "OK       CLAUDE.md: edits denied (${cm_first#covered })" ;;
  uncovered) log "NOTE     CLAUDE.md: no deny rule covers it in the settings read (project, local, user) — Daedalus may edit its own brief; promote and the launcher refuse while it differs from HEAD, and auto mode's classifier may still refuse the edit (README, \"Letting Daedalus edit its own CLAUDE.md\")" ;;
esac
case "$cm_state" in
  *classifyAllShell*) log "NOTE     auto mode: classifyAllShell is set in $user_settings, so the allow rule for core/lease.sh release is suspended and the classifier judges the delete (README, \"Windows (leases)\")" ;;
esac

# Promote (spec §15): the confirm mode, each target repo's trunk, the pre-push hook
# in each (git's own refusal of a trunk push no promotion confirmed), and a
# promotion prepared but never confirmed. One reader, core/promote.py --doctor;
# here-string loop so the MISSING count survives (see the leases block).
# Skipped, visibly absent, when a fixture has no promote.py.
if [ -f "$DAEDALUS_HOME/core/promote.py" ]; then
  pr_out="$(python3 "$DAEDALUS_HOME/core/promote.py" --doctor 2>/dev/null)"
  pr_rc=$?
  if [ "$pr_rc" -ne 0 ]; then
    note_problem "promote: check failed (core/promote.py --doctor exited $pr_rc)"
  else
    while IFS= read -r line; do
      case "$line" in
        "") ;;
        "MISSING  "*) note_problem "${line#MISSING  }" ;;
        *) log "$line" ;;
      esac
    done <<EOF
$pr_out
EOF
  fi
fi

# Arm-state visibility: claims() returns [] until vault/evidence/ has at
# least one dated *.md file, which is also what forces the first gates run
# to happen at all. That is a real gap, not a bug — but a silent one, since
# a deployment with no evidence yet is inert and gives no signal that it is.
# This is visibility only; nothing here runs gates.sh or writes evidence.
if [ ! -d "$DAEDALUS_HOME/vault/evidence" ] || [ -z "$(find "$DAEDALUS_HOME/vault/evidence" -maxdepth 1 -name '*.md' -print -quit 2>/dev/null)" ]; then
  log "NOTE     verify: stage unarmed — no evidence yet; run core/gates.sh once to arm it"
fi

# Unverified claims: a completion recorded without a PASS gate run for this
# deployment. Same rule as the Stop hook, over the whole vault.
#
# Captured into a variable first, then iterated with a here-string rather
# than piping straight into the while loop — a pipeline's right-hand side
# runs in a subshell, so note_problem's increment to $problems would not
# survive past the loop and every unverified claim would go uncounted even
# though it printed. The here-string keeps the loop (and note_problem) in
# the current shell.
#
# The exit code is checked too, right after the command substitution. A
# crashing verify-hook.py prints nothing to stdout, which previously read as
# "no unverified claims" — the doctor stayed green and silent on top of a
# broken claims-checker. That is this repo's founding pitfall class: a
# diagnostic for silent failure that failed silently. A non-zero exit is
# itself a problem, so it goes through note_problem and turns doctor red.
if [ -f "$DAEDALUS_HOME/core/verify-hook.py" ]; then
  unverified="$(python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note_problem "unverified-claims check failed (core/verify-hook.py --doctor exited $rc)"
  else
    while IFS= read -r line; do
      [ -n "$line" ] && note_problem "unverified claim: $line"
    done <<EOF
$unverified
EOF
  fi
fi

if [ "$problems" -ne 0 ]; then
  die "$problems problem(s) found"
fi
log "deployment is wired correctly"
