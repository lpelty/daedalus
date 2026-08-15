#!/usr/bin/env bash
# Shared helpers for Daedalus core scripts.
set -euo pipefail

DAEDALUS_HOME="${DAEDALUS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DAEDALUS_HOME
DAEDALUS_CONFIG="${DAEDALUS_CONFIG:-$DAEDALUS_HOME/config.yaml}"
export DAEDALUS_CONFIG

die() {
  printf 'daedalus: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'daedalus: %s\n' "$*"
}

# cfg <top.key> | <key> — print a scalar value from the config.
# A key that is present but has no value (e.g. "repo:" with nothing after
# the colon) is treated as missing — returns 1, prints nothing — because
# callers use cfg's success/failure to mean "I have a usable value," not
# merely "the key exists." A legitimately falsy-but-present value like
# "budget: 0" still has characters after trimming, so it still succeeds;
# only true emptiness (no characters) is treated as missing.
#
# `cfg` implements the narrow YAML SHAPE this product uses, not YAML itself.
# Rejecting the null spellings (~, null) is safe here only because every
# scalar in config.example.yaml is a URL, a branch name, or an integer —
# none of which can legitimately BE null. Do not extend this into a general
# rejection list; if the config surface ever needs richer values, replace the
# parser rather than adding spellings.
cfg() {
  local dotted="$1" top subkey
  [ -f "$DAEDALUS_CONFIG" ] || die "no config at $DAEDALUS_CONFIG (copy config.example.yaml)"
  case "$dotted" in
    *.*)
      top="${dotted%%.*}"
      subkey="${dotted#*.}"
      awk -v top="$top" -v subkey="$subkey" '
        $0 ~ "^"top":" { inblock=1; next }
        /^[^[:space:]#]/ { inblock=0 }
        inblock && $1 == subkey":" {
          line=$0
          sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)
          gsub(/^["\x27]|["\x27]$/, "", line)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (line == "" || line == "~" || tolower(line) == "null") exit 1
          print line
          found=1
          exit
        }
        END { exit(found ? 0 : 1) }
      ' "$DAEDALUS_CONFIG" || return 1
      ;;
    *)
      awk -v k="$dotted" '
        $1 == k":" {
          line=$0
          sub(/^[^:]+:[[:space:]]*/, "", line)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (line == "" || line == "~" || tolower(line) == "null") exit 1
          print line; found=1; exit
        }
        END { exit(found ? 0 : 1) }
      ' "$DAEDALUS_CONFIG" || return 1
      ;;
  esac
}

# cfg_list <key> — print one list item per line.
cfg_list() {
  local key="$1"
  [ -f "$DAEDALUS_CONFIG" ] || die "no config at $DAEDALUS_CONFIG"
  awk -v key="$key" '
    $0 ~ "^"key":" { inblock=1; next }
    /^[^[:space:]#-]/ { inblock=0 }
    inblock && /^[[:space:]]*-[[:space:]]/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^["\x27]|["\x27]$/, "", line)
      print line
    }
  ' "$DAEDALUS_CONFIG"
}

# cfg_pairs <dotted.key> — read a flat "a=1, b=2" mapping, print "a<TAB>1" per
# line. Returns 1 when the key is absent, or any entry lacks a path, lacks a
# value, or lacks the "=" separator between them. `*=?*`/`*?=*` check for a
# character on each side, not merely for the separator's presence — `a=*`
# alone would accept "a=" (empty value) since it only tests that an "="
# exists somewhere in the string. An empty path or empty URL is as unusable
# to Task 2's git-clone step as a missing "=" is, so all three are rejected
# the same way, with the same exit behavior.
#
# Flat on purpose: `cfg` parses the narrow YAML SHAPE this product uses, not
# YAML itself, and has no nested-map support. A block of maps would mean
# extending that parser — the same parser whose awk-builtin collision and
# multi-line truncation were v1's two config defects. A flat mapping needs
# no parser change at all.
#
# The split-and-validate loop runs via a here-string, not a pipe. Piping into
# `while` runs the loop in a subshell; here that subshell happens to be the
# pipeline's last stage, so under this file's `set -o pipefail` its exit
# status does reach the caller (verified empirically before choosing this
# form) — but that correctness is borrowed from pipefail plus the loop
# staying last in the pipe, not guaranteed by the loop itself. Any caller
# that ever wraps this in `$(...)` or adds a stage after the loop loses it
# silently. A here-string keeps the loop in the current shell function, so
# `return 1` reaches the caller unconditionally, with no dependency on
# shell options or pipeline position.
cfg_pairs() {
  local key="$1" raw entry path url
  raw="$(cfg "$key")" || return 1
  [ -n "$raw" ] || return 1
  while IFS= read -r entry; do
    entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$entry" ] || continue
    case "$entry" in
      ?*=?*) : ;;
      *) printf 'daedalus: config %s: entry %s needs a non-empty path and a non-empty url, as path=url\n' "$key" "$entry" >&2; return 1 ;;
    esac
    path="${entry%%=*}"
    url="${entry#*=}"
    printf '%s\t%s\n' "$path" "$url"
  done <<EOF
$(printf '%s\n' "$raw" | tr ',' '\n')
EOF
}

# repo_name <url> — basename of a git URL, without .git
repo_name() {
  local url="$1" base
  base="${url##*/}"
  printf '%s\n' "${base%.git}"
}

# target_path — absolute path to the target checkout.
#
# The directory name defaults to the repo URL's basename, but a deployment
# whose checkout directory differs from its repo name can override it with
# `target.dir`. cfg already treats a blank value, "~", and "null" as absent,
# so an empty `target.dir:` line falls back to the basename for free — no
# extra handling needed here.
#
# `target.dir` becomes a single path SEGMENT appended after $DAEDALUS_HOME/
# target/, not a multi-component path like target.nested — so it is rejected
# outright if it contains a "/" at all, which also catches an absolute form
# as a side effect. This is stricter than target.nested's guard (which must
# allow "/" for legitimate subdirectories, so it checks for ".." and a
# leading "/" specifically) because target.dir has no legitimate reason to
# contain a path separator: it names one directory, not a location. A bare
# "." or ".." has no "/" but is still a traversal (target/.. resolves to
# $DAEDALUS_HOME itself), so it is checked separately.
target_path() {
  local url name dir
  url="$(cfg target.repo)" || die "config: target.repo is required"
  name="$(repo_name "$url")"
  dir="$(cfg target.dir 2>/dev/null || true)"
  if [ -n "$dir" ]; then
    case "$dir" in
      */*|.|..) die "config target.dir: $dir must be a single directory name, not a path" ;;
    esac
    name="$dir"
  fi
  printf '%s\n' "$DAEDALUS_HOME/target/$name"
}

# scaffold_repo <url> <dest> — recreate a repo's TOP-LEVEL DIRECTORY NAMES at
# <dest>, empty, plus a placeholder hot.md. File contents are never
# downloaded.
#
# A target harness's vault holds the operator's private material, which has no
# bearing on whether the harness works — but scripts write into those paths, so
# verification needs the directories to exist. --filter=blob:none --no-checkout
# fetches the tree alone; no file content reaches disk.
#
# Top-level only, deliberately: inventing nested structure to satisfy a guess
# manufactures the confusion it means to prevent. A script that fails on a
# missing nested path is a finding with evidence behind it.
#
# Destination-path validation is NOT this function's job. It runs `mkdir -p`
# on whatever `dest` it is given, the same way `cfg_pairs` returns a raw
# path=url pair without judging it. The caller (setup.sh, Task 4) owns
# rejecting a traversal-shaped destination before calling here — mirroring
# how sync-target.sh, not lib.sh, owns the target.nested boundary guard.
#
# DAEDALUS_SCAFFOLD_KEEP_TMP=1 skips the temp-dir cleanup and prints its path
# on stdout as `KEPT_TMP=<path>` (test-only escape hatch). This exists so a
# test can inspect the clone for blob content directly, rather than trusting
# code inspection that --filter=blob:none --no-checkout is actually in
# effect — a future edit could drop those flags and every existing test
# would still pass, because they only ever look at $dest, never at $tmp,
# and $tmp is gone by the time an assertion runs.
scaffold_repo() {
  local url="$1" dest="$2" tmp d existing
  [ -n "$url" ] || die "scaffold_repo: url is required"
  [ -n "$dest" ] || die "scaffold_repo: dest is required"

  tmp="$(mktemp -d)" || die "scaffold_repo: could not create a temp dir"
  if git clone --quiet --depth 1 --filter=blob:none --no-checkout "$url" "$tmp/shape" 2>/dev/null; then
    :
  else
    rm -rf "$tmp"
    die "scaffold_repo: could not read $url"
  fi

  mkdir -p "$dest"
  git -C "$tmp/shape" ls-tree -d --name-only HEAD > "$tmp/dirs" || {
    rm -rf "$tmp"
    die "scaffold_repo: could not list the tree of $url"
  }
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in
      .*) continue ;;   # app config such as .obsidian is not vault taxonomy
    esac
    mkdir -p "$dest/$d"
  done < "$tmp/dirs"

  # Drift visibility: a destination directory with no counterpart in the
  # source's current top-level shape is logged, never deleted. Deleting on a
  # caller-supplied destination is a bigger hazard than a stale empty
  # directory — this product has already shipped one path-traversal escape
  # from a delete-adjacent operation (Task 2). Silence here would mean the
  # destination can drift from the source indefinitely with no signal.
  if [ -d "$dest" ]; then
    for existing in "$dest"/*/; do
      [ -d "$existing" ] || continue
      d="$(basename "$existing")"
      case "$d" in
        .*) continue ;;
      esac
      if ! grep -qxF "$d" "$tmp/dirs"; then
        log "scaffold: $d exists at destination but not in $url's current shape (left in place)"
      fi
    done
  fi

  if [ -f "$dest/hot.md" ]; then
    :
  else
    printf '%s\n' "Placeholder — this file exists so scripts that write rolling state have a target. It carries no state." > "$dest/hot.md"
  fi

  if [ "${DAEDALUS_SCAFFOLD_KEEP_TMP:-}" = "1" ]; then
    printf 'KEPT_TMP=%s\n' "$tmp"
  else
    rm -rf "$tmp"
  fi
  log "scaffolded $(basename "$dest") from $url"
}
