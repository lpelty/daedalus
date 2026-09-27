#!/usr/bin/env bash
# The only sanctioned way to commit the vault from a session (spec §4.7).
#   core/vault-commit.sh [-m "<message>"] [--push]
# 1. the prime window or an operator shell only; 2. vault index.lock is
# retried three times, a second apart; 3–4. every claim-shaped changed or
# untracked document is judged, whatever lease: it carries — a live other
# window's claim is left out of the commit and named, a dead window's
# unverified claim stops the commit (the prime answers for it), two files with
# one EX/PROP number stop it (a number is never renumbered by another
# session); 5. commit with the given message or "vault: prime commit <date>
# (leases: …)"; 6. --push pushes a vault that has an origin.
# guard-bash.py denies raw git add/commit/stash under vault/ from every
# session so that this check is never skipped; an operator at a shell is
# free to type git commit there.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
V="$DAEDALUS_HOME/vault"
LL="$DAEDALUS_HOME/core/leaselib.py"
msg=""; push=0
while [ $# -gt 0 ]; do
  case "$1" in
    -m) [ $# -ge 2 ] || die 'usage: core/vault-commit.sh [-m "<message>"] [--push]'; msg="$2"; shift 2 ;;
    --push) push=1; shift ;;
    *) die 'usage: core/vault-commit.sh [-m "<message>"] [--push]' ;;
  esac
done
[ -e "$V/.git" ] || die "the vault at $V is not its own git repository"

# 1. Only the prime window commits (§4.7); a shell with no session identity is the operator.
if python3 "$LL" my-session >/dev/null 2>&1; then
  if ! python3 "$LL" is-prime; then
    sentence="$(python3 "$LL" not-prime-sentence 2>&1)" || die "$sentence"
    die "$sentence"
  fi
fi

# 2. retry_git <args...> — three tries, a second apart, while another session holds index.lock (§3.3).
retry_git() {
  local n=0 out
  while :; do
    if out="$(git -C "$V" "$@" 2>&1)"; then printf '%s\n' "$out"; return 0; fi
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
retry_git add -A >/dev/null || die "git add failed in the vault"
while IFS= read -r p; do [ -n "$p" ] && git -C "$V" reset -q -- "$p"; done <<EOF
$skip
EOF
if git -C "$V" diff --cached --quiet; then
  log "nothing to commit"
else
  [ -n "$msg" ] || msg="vault: prime commit $(date +%Y-%m-%d) (leases: ${leases:-none})"
  # The vault's own identity when it has one; a placeholder only where none is configured.
  ident=""
  if ! git -C "$V" config user.email >/dev/null 2>&1 || ! git -C "$V" config user.name >/dev/null 2>&1; then
    ident="-c user.email=${GIT_AUTHOR_EMAIL:-daedalus@localhost} -c user.name=${GIT_AUTHOR_NAME:-daedalus}"
  fi
  # shellcheck disable=SC2086
  retry_git $ident commit -q -m "$msg" >/dev/null || die "commit failed in the vault"
  log "committed: $msg"
fi

# 6. --push (also with nothing new to commit: an earlier commit may still be unpushed)
if [ "$push" -eq 1 ]; then
  git -C "$V" remote get-url origin >/dev/null 2>&1 || die "the vault has no origin to push to"
  retry_git push -q >/dev/null || die "push failed"
  log "pushed"
fi
