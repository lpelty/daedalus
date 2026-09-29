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

# daedalus_version — the release this checkout is (spec §14): VERSION's first
# line, trimmed, when it reads X.Y.Z. Returns 1, printing nothing, when the file
# is absent, empty or anything else — a checkout from before v0.7.0 has none.
daedalus_version() {
  local ver
  [ -f "$DAEDALUS_HOME/VERSION" ] || return 1
  ver="$(head -n 1 "$DAEDALUS_HOME/VERSION" | tr -d '[:space:]')"
  case "$ver" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac
  case "$ver" in
    *.*.*.*) return 1 ;;
    *.*.*) printf '%s\n' "$ver" ;;
    *) return 1 ;;
  esac
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

# is_work_tree_root <dir> — true when <dir> is the ROOT of a git work tree:
# a main checkout, a linked worktree (whose .git is a FILE, so `-d .git` says
# no), or a nested repository. False for a subdirectory of a repository, for
# an empty directory that merely sits inside an outer repository (a real
# deployment's DAEDALUS_HOME is one), for a missing path, for a bare
# repository and for a .git directory itself.
#
# Ask git for both facts in one call and compare the whole answer:
# `--is-inside-work-tree` prints true/false, `--show-prefix` prints the
# path from the work tree's root to <dir> — empty at the root. Output of
# exactly `true` means inside AND at the root. Never compare paths: the
# earlier form matched `--show-toplevel` against `pwd -P`, and on macOS's
# case-insensitive volume git prints the on-disk spelling while /bin/bash
# 3.2's `pwd -P` keeps the caller's — a DAEDALUS_HOME reached through a
# differently-cased path nulled every fingerprint and made sync-target
# `git clone` over its own checkout (Task 13 review). Verified against git
# 2.50 for each case listed above before writing.
is_work_tree_root() {
  local answer
  answer="$(git -C "$1" rev-parse --is-inside-work-tree --show-prefix 2>/dev/null)" || return 1
  [ "$answer" = true ]
}

# repo_name <url> — basename of a git URL, without .git
repo_name() {
  local url="$1" base
  base="${url##*/}"
  printf '%s\n' "${base%.git}"
}

# target_name — the checkout's directory name, from config ALONE (target.repo
# basename, or target.dir). Lease-agnostic on purpose: allocating a window
# needs the name before that window has a lease, and must never go through
# target_path (which, once leases exist, fails closed for exactly that session).
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
target_name() {
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
  printf '%s\n' "$name"
}

# target_path — absolute path to the tree this caller builds in: target_name
# under $DAEDALUS_HOME/target/ (the tree rule), or the caller's lease worktree.
target_path() {
  local name
  name="$(target_name)" || return 1
  # Lease resolution (spec §4.4): when any lease file exists, the tree a
  # session builds in is decided by ONE implementation, core/leaselib.py,
  # which fails closed for an unbindable session and prints a note for an
  # operator shell. With no lease files the bash path spawns nothing.
  # target_name above never consults the leases — allocation depends on that.
  # (`exit 3` inside a "$(...)" substitution exits only that subshell; callers
  # already treat a non-zero target_path as failure. Never call this from
  # under the lease lock: the child takes LOCK_SH and would wait forever.)
  if [ -n "$(ls "$DAEDALUS_HOME/state/leases"/*.json 2>/dev/null)" ] || [ -n "${DAEDALUS_TARGET_OVERRIDE:-}" ]; then
    python3 "$DAEDALUS_HOME/core/leaselib.py" resolve "$name" || exit 3
    return 0
  fi
  printf '%s\n' "$DAEDALUS_HOME/target/$name"
}

# The variables capture reads (core/capture.py) — the names memory_env exports.
MEMORY_ENV_VARS="TENANT_HOME TENANT_BANK HINDSIGHT_API_URL TRANSCRIPT_DIR CAPTURE_INTERVAL HINDSIGHT_API_TENANT_API_KEY TENANT_USER_LABEL TENANT_ASSISTANT_LABEL"

# memory_configured — true when config.yaml carries a top-level memory: block
# (spec §4.7). Presence only; memory_env judges whether the fields are usable.
memory_configured() {
  [ -f "$DAEDALUS_CONFIG" ] && grep -q '^memory:' "$DAEDALUS_CONFIG"
}

# memory_env — print `export NAME=value` lines for episodic capture (spec §4.7
# "Where capture's configuration lives — one place"). The memory: block is THE
# source; a variable already in the environment overrides its field, so a hook
# line written for an older release (VAR=… prefixes) keeps working through the
# upgrade. Callers: eval "$(memory_env)" — close.sh, capture-tick.sh, and the
# direct-call launcher (plan 3). Values are %q-quoted, so eval takes them
# literally. Returns 1 with ONE plain sentence on stderr and nothing on stdout
# when there is no bank or a field is unusable. The API key is read from
# memory.api_key_file (a 0600 file under the home) so it never sits on a hook
# command line, where any process listing shows it; it is never printed in a
# message.
memory_env() {
  local bank home api interval interval_ok tdir phys key keyfile mode ulabel alabel
  bank="${TENANT_BANK:-$(cfg memory.bank 2>/dev/null || true)}"
  if [ -z "$bank" ]; then
    printf 'daedalus: episodic capture needs memory.bank in config.yaml (or TENANT_BANK in the environment) — see "Episodic memory capture" in README.md\n' >&2
    return 1
  fi
  home="${TENANT_HOME:-$DAEDALUS_HOME}"
  api="${HINDSIGHT_API_URL:-$(cfg memory.api_url 2>/dev/null || printf 'http://127.0.0.1:8888')}"
  interval="${CAPTURE_INTERVAL:-$(cfg memory.capture_interval 2>/dev/null || printf 120)}"
  case "$interval" in
    ''|*[!0-9]*) interval_ok=0 ;;
    *) if [ "${#interval}" -le 6 ] && [ "$interval" -gt 0 ]; then interval_ok=1; else interval_ok=0; fi ;;
  esac
  if [ "$interval_ok" -ne 1 ]; then
    printf 'daedalus: memory.capture_interval must be a whole number of seconds > 0 (got: %s)\n' "$interval" >&2
    return 1
  fi
  tdir="${TRANSCRIPT_DIR:-$(cfg memory.transcript_dir 2>/dev/null || true)}"
  if [ -z "$tdir" ]; then
    # Claude Code's project directory for this home: the resolved path with
    # every character other than a letter or digit as - (Claude Code's rule,
    # verified against a live home 2026-09-13; it slugs the physical cwd, so
    # /tmp becomes -private-tmp). The hook payload's transcript_path and the
    # SessionStart marker come first; this is the last resort.
    phys="$(cd "$DAEDALUS_HOME" 2>/dev/null && pwd -P)" || phys="$DAEDALUS_HOME"
    tdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$phys" | sed 's/[^A-Za-z0-9]/-/g')"
  fi
  key="${HINDSIGHT_API_TENANT_API_KEY:-}"
  if [ -z "$key" ] && keyfile="$(cfg memory.api_key_file 2>/dev/null)"; then
    case "$keyfile" in
      /*|..|../*|*/..|*/../*)
        printf 'daedalus: memory.api_key_file must be a path under the Daedalus home, not absolute and without .. (got: %s)\n' "$keyfile" >&2
        return 1 ;;
    esac
    if [ ! -f "$DAEDALUS_HOME/$keyfile" ]; then
      printf 'daedalus: memory.api_key_file %s does not exist\n' "$keyfile" >&2
      return 1
    fi
    mode="$(python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$DAEDALUS_HOME/$keyfile")"
    case "$mode" in
      600|400) : ;;
      *) printf 'daedalus: memory.api_key_file %s is readable by others (mode %s); run chmod 600 %s\n' "$keyfile" "$mode" "$keyfile" >&2
         return 1 ;;
    esac
    key="$(head -n 1 "$DAEDALUS_HOME/$keyfile" | tr -d '[:space:]')"
    # A configured file that yields no key is an error, not "no key": falling
    # back would post unauthenticated and the background tick would only see 401s.
    if [ -z "$key" ]; then
      printf 'daedalus: memory.api_key_file %s is empty — put the REST API key on its first line\n' "$keyfile" >&2
      return 1
    fi
  fi
  ulabel="${TENANT_USER_LABEL:-$(cfg memory.user_label 2>/dev/null || true)}"
  alabel="${TENANT_ASSISTANT_LABEL:-$(cfg memory.assistant_label 2>/dev/null || true)}"
  printf 'export TENANT_HOME=%q\n' "$home"
  printf 'export TENANT_BANK=%q\n' "$bank"
  printf 'export HINDSIGHT_API_URL=%q\n' "$api"
  printf 'export TRANSCRIPT_DIR=%q\n' "$tdir"
  printf 'export CAPTURE_INTERVAL=%q\n' "$interval"
  if [ -n "$key" ]; then printf 'export HINDSIGHT_API_TENANT_API_KEY=%q\n' "$key"; fi
  if [ -n "$ulabel" ]; then printf 'export TENANT_USER_LABEL=%q\n' "$ulabel"; fi
  if [ -n "$alabel" ]; then printf 'export TENANT_ASSISTANT_LABEL=%q\n' "$alabel"; fi
  return 0
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
# verify.refute_timeout, validated: a whole number of seconds, 1..9999999
# (a longer string overflows the watchdog's float conversion, and no review
# takes 115 days). Absent, empty, `~` and `null` all mean the default 600 —
# the absent-equals-empty convention cfg applies to every key. Prints the
# seconds; on a bad value prints the reason to stderr and returns 1, so each
# caller picks its own exit: gates.sh dies before any evidence exists,
# refute.sh exits 2 (cannot certify).
refute_timeout() {
  local t
  t="$(cfg verify.refute_timeout 2>/dev/null || printf 600)"
  case "$t" in
    *[!0-9]*) : ;;
    *) if [ "${#t}" -le 7 ] && [ "$t" -gt 0 ]; then printf '%s\n' "$t"; return 0; fi ;;
  esac
  printf 'verify.refute_timeout must be a whole number of seconds > 0 (got: %s)\n' "$t" >&2
  return 1
}

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
