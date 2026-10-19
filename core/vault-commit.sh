#!/usr/bin/env bash
# The only sanctioned way to commit the vault from a session (spec §4.7).
#   core/vault-commit.sh [-m "<message>"] [--push]
# 1. the pen's holder or an operator shell only — a pen whose holder has ended
# moves to a terminal session here; behind a live holder, exit 3 and one line
# (not committed here: the pen's holder commits); 2. vault index.lock is
# retried three times, a second apart; 3–4. every claim-shaped changed or
# untracked document is judged, whatever lease: it carries — a live other
# window's claim is left out of the commit and named, a dead window's
# unverified claim stops the commit (the prime answers for it), two files with
# one EX/PROP number stop it (a number is never renumbered by another
# session); 5. commit with the given message or "vault: prime commit <date>
# (leases: …)", then kick the document index rebuild in the background
# (core/vault-search.py index --background — a line, never a failed commit);
# 6. --push pushes a vault that has an origin.
# Session logs (2026-10-19): a full commit leaves out another session's log while that session is still open and
# has not closed (its work in progress), carries every other one, and names whose logs it carried; the pending
# markers closed windows left (state/vault-pending/) are cleared once their logs are in.
#   core/vault-commit.sh --pending — the pen's holder's Stop and SessionEnd hooks: commit only the logs closed
# windows marked pending (git commit --only), nothing else; silent, exit 0 on every path.
# guard-bash.py denies raw git add/commit/stash under vault/ from every
# session so that this check is never skipped; an operator at a shell is
# free to type git commit there.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
V="$DAEDALUS_HOME/vault"
LL="$DAEDALUS_HOME/core/leaselib.py"
msg=""; push=0; pending_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    -m) [ $# -ge 2 ] || die 'usage: core/vault-commit.sh [-m "<message>"] [--push] | --pending'; msg="$2"; shift 2 ;;
    --push) push=1; shift ;;
    --pending) pending_only=1; shift ;;
    *) die 'usage: core/vault-commit.sh [-m "<message>"] [--push] | --pending' ;;
  esac
done
# --pending: never a word, never a failure (a hook's) — every refusal below ends it quietly.
if [ "$pending_only" -eq 1 ]; then
  [ -n "$(python3 "$LL" pending-logs 2>/dev/null)" ] || exit 0
  python3 "$LL" is-prime >/dev/null 2>&1 || exit 0          # the pen's holder only; never a take from a hook
  exec >/dev/null 2>&1
  die() { exit 0; }
fi
# The vault is its own repository, or a directory the Daedalus home repository
# tracks (the two layouts doctor accepts). In the second, the commit is made in
# that repository and must carry the vault alone: work the operator has staged
# there outside vault/ is theirs to commit, so it refuses by name.
if [ -e "$V/.git" ]; then
  G="$V"; SPEC=""
elif git -C "$DAEDALUS_HOME" ls-files --error-unmatch vault >/dev/null 2>&1; then
  G="$DAEDALUS_HOME"; SPEC="vault"
  # A tracked vault that an ignore rule still matches (force-added once) makes `git add -A -- vault`
  # refuse every new file: say the cause and the fix, not git's hint.
  # check-ignore -v reports the last matching rule and exits 0 even when that rule is a negation
  # (`!/vault/`, which daedalus update writes in a home that keeps its own vault): only a rule
  # without "!" ignores. Its output is <source>:<line>:<pattern><TAB><path>.
  if ign="$(git -C "$G" check-ignore -v --no-index -- vault 2>/dev/null)"; then   # --no-index: a tracked path is otherwise never reported
    rule="${ign%%	*}"; src="${rule%%:*}"; rule="${rule#*:}"; rule="${rule#*:}"
    case "$src" in /*) : ;; *) src="$G/$src" ;; esac
    case "$rule" in '!'*) : ;; *) die "vault/ is ignored by $src (the rule \`$rule\`); remove that line — a tracked directory stays tracked — and run core/vault-commit.sh again" ;; esac
  fi
  # The whole index of that repository, which may be larger than the home (a home inside a
  # ship repo): --show-prefix is the home's path from the repository root, "" at the root.
  # core.quotepath=false: a name with accents is listed as itself, not C-quoted.
  prefix="$(git -C "$G" rev-parse --show-prefix)"
  staged=""
  while IFS= read -r f; do
    case "$f" in "${prefix}vault/"*|"") ;; *) staged="$staged$f "; [ "$(printf '%s' "$staged" | wc -w)" -lt 3 ] || break ;; esac
  done <<EOF
$(git -C "$G" -c core.quotepath=false diff --cached --name-only)
EOF
  [ -z "$staged" ] || die "the repository holding the vault has staged changes outside vault/ (${staged% }); commit or unstage them first, then run core/vault-commit.sh again"
else
  die "the vault at $V is neither its own git repository nor tracked by the Daedalus home repository ($DAEDALUS_HOME)"
fi

# git_path <home-relative path> — the path as git -C "$G" takes it (vault/x in the home layout, x in the vault's own).
git_path() { if [ -n "$SPEC" ]; then printf '%s' "$1"; else printf '%s' "${1#vault/}"; fi; }
# vault_ident — the vault's own identity when it has one; a placeholder only where none is configured.
vault_ident() {
  if ! git -C "$G" config user.email >/dev/null 2>&1 || ! git -C "$G" config user.name >/dev/null 2>&1; then
    printf '%s' "-c user.email=${GIT_AUTHOR_EMAIL:-daedalus@localhost} -c user.name=${GIT_AUTHOR_NAME:-daedalus}"
  fi
}
# clear_landed — drop each pending marker whose log is now committed (clean in git).
clear_landed() {
  local rel landed=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -n "$(git -C "$G" status --porcelain -- "$(git_path "$rel")" 2>/dev/null)" ] || landed="$landed $rel"
  done <<PEND
$(python3 "$LL" pending-logs 2>/dev/null)
PEND
  # shellcheck disable=SC2086
  [ -z "$landed" ] || python3 "$LL" clear-pending $landed >/dev/null 2>&1 || true
}

if [ "$pending_only" -eq 1 ]; then
  set -- ; names=""
  while IFS= read -r rel; do
    [ -n "$rel" ] && [ -f "$DAEDALUS_HOME/$rel" ] || continue
    gp="$(git_path "$rel")"
    [ -n "$(git -C "$G" status --porcelain -- "$gp" 2>/dev/null)" ] || continue
    set -- "$@" "$gp"; names="${names:+$names, }$(basename "$rel" .md)"
  done <<PEND
$(python3 "$LL" pending-logs 2>/dev/null)
PEND
  if [ $# -gt 0 ]; then
    ident="$(vault_ident)"
    # shellcheck disable=SC2086
    git -C "$G" add -- "$@" && git -C "$G" $ident commit -q --only -m "vault: closed windows' session logs ($names)" -- "$@" || exit 0
  fi
  clear_landed
  exit 0
fi

# 1. The pen's holder commits (§4.7); a shell with no session identity is the operator. A pen whose
# holder has ended moves to this session when it is a terminal session (leaselib pen-for-commit, one
# locked judge-and-write). Exit 3: not committed here — the pen's holder commits; its one line says why.
# rc=0 … || rc=$?: lib.sh sets -e, so a bare `said=$(…); rc=$?` would end the script silently at exit 3.
if python3 "$LL" my-session >/dev/null 2>&1; then
  rc=0; said="$(python3 "$LL" pen-for-commit 2>&1)" || rc=$?
  case $rc in
    0) [ -z "$said" ] || log "$said" ;;
    3) printf 'daedalus: %s\n' "$said" >&2; exit 3 ;;
    *) die "${said#daedalus: }" ;;
  esac
fi

# 2. retry_git <args...> — three tries, a second apart, while another session holds index.lock (§3.3).
retry_git() {
  local n=0 out
  while :; do
    if out="$(git -C "$G" "$@" 2>&1)"; then printf '%s\n' "$out"; return 0; fi
    case "$out" in
      *index.lock*) n=$((n + 1)); [ "$n" -lt 3 ] || { printf '%s\n' "$out" >&2; return 1; }; sleep 1 ;;
      *) printf '%s\n' "$out" >&2; return 1 ;;
    esac
  done
}

# doc_window <file> — "window NN" from the document's lease: line, or nothing.
doc_window() {
  local nn
  nn="$(sed -n '2,/^---$/p' "$1" | sed -n 's/^lease:[[:space:]]*\([0-9][0-9]\).*/\1/p' | head -1)"
  [ -n "$nn" ] && printf ' (window %s)' "$nn"
  return 0
}

# 3. Two files with one EX/PROP number stop the commit: a number the operator has
# seen is one they will say again, so nobody renumbers another session's document (§4.7).
dup="$( { ls "$V"/exchange/messages/EX-*.md "$V"/proposals/PROP-*.md 2>/dev/null || true; } \
        | sed -E 's#.*/((EX|PROP)-[0-9]+).*#\1#' | sort | uniq -d | head -1)"
if [ -n "$dup" ]; then
  names=""
  for f in "$V"/exchange/messages/"$dup"*.md "$V"/proposals/"$dup"*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in "$dup".md|"$dup"-*) : ;; *) continue ;; esac   # PROP-2, never PROP-20
    names="${names:+$names and }${b%.md}$(doc_window "$f")"
  done
  die "$dup exists twice: $names; the later one renumbers its own file"
fi

# 4. Per-file staging from the claim report — one JSON object per claim-shaped document.
# Every lease-derived input is read HERE, before anything is staged: a lease
# file that cannot be read refuses the whole commit (the report fails closed and
# its sentence names the file), and the window numbers for the default message
# are read now rather than after `git add -A`, where a refusal would leave the
# index dirtied with no sentence at all (Task 16 review). Never send a
# leaselib call's stderr to /dev/null — its failure is the operator's to see.
leases="$(python3 "$LL" numbers 2>&1)" || die "${leases#daedalus: }"
leases="$(printf '%s\n' "$leases" | tr '\n' ',' | sed 's/^,*//; s/,$//; s/,/, /g')"
report="$(python3 "$DAEDALUS_HOME/core/verifylib.py" --vault-claims)" || die "the vault's claims could not be checked, so nothing was staged"
skip=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  fields="$(printf '%s' "$row" | python3 -c 'import json,sys
d=json.load(sys.stdin); print("\t".join([d["path"], d["lease"], "1" if d["live"] else "0", "1" if d["own"] else "0", d["problem"] or ""]))')"
  path="${fields%%	*}"; rest="${fields#*	}"
  lease="${rest%%	*}"; rest="${rest#*	}"
  live="${rest%%	*}"; rest="${rest#*	}"
  own="${rest%%	*}"; problem="${rest#*	}"
  if [ "$live" = 1 ] && [ "$own" = 0 ]; then
    log "left uncommitted: $(basename "$path") (window $lease, still live) — its own session verifies it"
    skip="$skip
$path"
    continue
  fi
  if [ -n "$problem" ]; then
    [ -n "$lease" ] && [ "$own" = 0 ] && problem="$problem (window $lease has no live session, so the prime answers for it)"
    die "$problem"
  fi
done <<EOF
$report
EOF

# 5. Stage everything, take the live other windows' claims back out, commit.
retry_git add -A ${SPEC:+-- "$SPEC"} >/dev/null || die "git add failed in the vault"
while IFS= read -r p; do [ -n "$p" ] && git -C "$G" reset -q -- "$p"; done <<EOF
$skip
EOF
# Session logs: another open session's log is its work in progress (left out, named); every other session's log in
# this commit is carried, and the line names whose.
logrows="$(python3 "$LL" vault-logs 2>&1)" || die "${logrows#daedalus: }"
held=""; carried=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  f="$(printf '%s' "$row" | python3 -c 'import json,sys
d=json.load(sys.stdin); print("\t".join([d["path"], d["owner"], "1" if d["mine"] else "0", "1" if d["hold"] else "0"]))')"
  rel="${f%%	*}"; rest="${f#*	}"; owner="${rest%%	*}"; rest="${rest#*	}"; mine="${rest%%	*}"; hold="${rest#*	}"
  gp="$(git_path "$rel")"
  [ -n "$(git -C "$G" diff --cached --name-only -- "$gp")" ] || continue
  if [ "$hold" = 1 ]; then
    git -C "$G" reset -q -- "$gp"; held="${held:+$held, }$owner"
  elif [ "$mine" = 0 ]; then
    carried="${carried:+$carried, }$owner ($(basename "$rel" .md))"
  fi
done <<EOF
$logrows
EOF
[ -z "$held" ] || log "left out, still being written: the session log of $held"
[ -z "$carried" ] || log "carried the session log of $carried"
if git -C "$G" diff --cached --quiet; then
  log "nothing to commit"
else
  [ -n "$msg" ] || msg="vault: prime commit $(date +%Y-%m-%d) (leases: ${leases:-none})"
  ident="$(vault_ident)"
  # shellcheck disable=SC2086
  retry_git $ident commit -q -m "$msg" >/dev/null || die "commit failed in the vault"
  log "committed: $msg"
  clear_landed
  # 5b. The document index follows the vault (reindex design 2026-10-15): kicked after a commit it
  # made, in the background, never holding this turn; a failure is a line, never a failed commit.
  # The kick's cwd is the home, so a close.sh run from a worktree still resolves the right script.
  if [ -f "$DAEDALUS_HOME/core/vault-search.py" ]; then
    if idx="$(cd "$DAEDALUS_HOME" && python3 "$DAEDALUS_HOME/core/vault-search.py" index --background --by vault-commit 2>&1)"; then
      [ -n "$idx" ] || idx="document index: not started (core/vault-search.py said nothing); run it with python3 core/vault-search.py index"
      log "$idx"
    else
      rc=$?
      log "document index: not started (core/vault-search.py exited $rc); run it with python3 core/vault-search.py index"
    fi
  fi
fi

# 6. --push (also with nothing new to commit: an earlier commit may still be unpushed)
if [ "$push" -eq 1 ]; then
  git -C "$G" remote get-url origin >/dev/null 2>&1 || die "the repository holding the vault has no origin to push to"
  retry_git push -q >/dev/null || die "push failed"
  log "pushed"
fi
