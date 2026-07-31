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
