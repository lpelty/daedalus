#!/usr/bin/env python3
"""The pitfalls a refuter run should read: every pitfall in vault/pitfalls/
whose `applies-to: path:` glob matches a path the diff touches, plus every
pitfall with no `applies-to:` at all (one that "waits to be asked" — a
review is the asking). Pitfalls with only `bash:` patterns are about
commands, not files; a diff has no commands, so they are left out.

    python3 core/refute-pitfalls.py [--list-out F] [--only F] <paths-file>

<paths-file> holds one diff path per line, relative to the target root —
the frame `applies-to: path:` globs are written in. Prints markdown to
stdout: one section per pitfall (title, source file, body with the
frontmatter stripped), or nothing when none applies. Exit 0 either way;
a bad paths-file is exit 1 with the reason on stderr.

A promote review is re-rendered byte for byte at confirm (spec §6.1), so the
set of pitfalls it showed is pinned: --list-out F writes the chosen pitfall
files, one absolute path per line in the order shown; --only F renders
exactly the files F lists, in that order, whatever the selection would say
now (a listed file that is gone or unparseable is exit 1).

Matching and parsing come from core/pitfall-inject.py — the hook's own
grammar, loaded by path because the file name has a hyphen. One matcher,
one parser, sited there. Python 3.9, standard library only.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import List, Optional

MAX_CHARS = 40000


def _load_hook():
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location("pitfall_inject", str(here / "pitfall-inject.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def applicable(root: Path, diff_paths: List[str]):
    hook = _load_hook()
    good, _skipped = hook.load_pitfalls(root)
    out = []
    for p in good:
        if not p["bash"] and not p["path"]:
            out.append(p)
            continue
        if any(hook.search(rx, rel, full=True) for rx in p["path_regex"] for rel in diff_paths):
            out.append(p)
    return out, hook


def pinned(root: Path, only: List[str]):
    hook = _load_hook()
    good, _skipped = hook.load_pitfalls(root)
    by_file = {str(Path(p["file"]).resolve()): p for p in good}
    out = []
    for f in only:
        p = by_file.get(str(Path(f).resolve()))
        if p is None:
            raise ValueError("a pinned pitfall is gone or no longer parses: %s" % f)
        out.append(p)
    return out, hook


def render(root: Path, diff_paths: List[str], only: Optional[List[str]] = None,
           list_out: Optional[str] = None) -> str:
    chosen, hook = pinned(root, only) if only is not None else applicable(root, diff_paths)
    if list_out:
        Path(list_out).write_text("".join(str(Path(p["file"]).resolve()) + "\n" for p in chosen))
    parts: List[str] = []
    for p in chosen:
        try:
            _fields, body = hook.parse_frontmatter(Path(p["file"]).read_text(encoding="utf-8"))
        except Exception:
            body = [p["first_paragraph"]]
        text = "\n".join(body).strip("\n")
        # The body's own H1 supplied the title; printing it twice reads as
        # two pitfalls.
        first, _, rest = text.partition("\n")
        if first.strip().startswith("# ") and first.strip()[2:].strip() == p["title"]:
            text = rest.strip("\n")
        parts.append("### Pitfall: %s\n(source: %s)\n\n%s\n" % (p["title"] or Path(p["file"]).name, p["file"], text))
    doc = "\n".join(parts)
    if len(doc) > MAX_CHARS:
        doc = doc[:MAX_CHARS] + "\n\n(pitfalls truncated at %d characters)\n" % MAX_CHARS
    return doc


def main(argv: List[str]) -> int:
    args = argv[1:]
    opts = {}
    for flag in ("--list-out", "--only"):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                sys.stderr.write("refute-pitfalls: %s needs a file\n" % flag)
                return 1
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 1:
        sys.stderr.write("usage: refute-pitfalls.py [--list-out F] [--only F] <paths-file>\n")
        return 1
    try:
        raw = Path(args[0]).read_text(encoding="utf-8", errors="replace")
        only = None
        if "--only" in opts:
            only = [ln.strip() for ln in Path(opts["--only"]).read_text().splitlines() if ln.strip()]
    except OSError as e:
        sys.stderr.write("refute-pitfalls: %s\n" % e)
        return 1
    diff_paths = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    hook = _load_hook()
    try:
        sys.stdout.write(render(hook.daedalus_root(), diff_paths, only=only, list_out=opts.get("--list-out")))
    except ValueError as e:
        sys.stderr.write("refute-pitfalls: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
