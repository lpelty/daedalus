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
# line. Returns 1 when the key is absent or any entry lacks an equals sign.
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
      *=*) : ;;
      *) printf 'daedalus: config %s: entry %s needs the form path=url\n' "$key" "$entry" >&2; return 1 ;;
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
target_path() {
  local url name
  url="$(cfg target.repo)" || die "config: target.repo is required"
  name="$(repo_name "$url")"
  printf '%s\n' "$DAEDALUS_HOME/target/$name"
}
