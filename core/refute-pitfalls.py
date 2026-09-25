#!/usr/bin/env python3
"""The pitfalls a refuter run should read: every pitfall in vault/pitfalls/
whose `applies-to: path:` glob matches a path the diff touches, plus every
pitfall with no `applies-to:` at all (one that "waits to be asked" — a
review is the asking). Pitfalls with only `bash:` patterns are about
commands, not files; a diff has no commands, so they are left out.

    python3 core/refute-pitfalls.py <paths-file>

<paths-file> holds one diff path per line, relative to the target root —
the frame `applies-to: path:` globs are written in. Prints markdown to
stdout: one section per pitfall (title, source file, body with the
frontmatter stripped), or nothing when none applies. Exit 0 either way;
a bad paths-file is exit 1 with the reason on stderr.

Matching and parsing come from core/pitfall-inject.py — the hook's own
grammar, loaded by path because the file name has a hyphen. One matcher,
one parser, sited there. Python 3.9, standard library only.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import List

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


def render(root: Path, diff_paths: List[str]) -> str:
    chosen, hook = applicable(root, diff_paths)
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
    if len(argv) != 2:
        sys.stderr.write("usage: refute-pitfalls.py <paths-file>\n")
        return 1
    try:
        raw = Path(argv[1]).read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        sys.stderr.write("refute-pitfalls: %s\n" % e)
        return 1
    diff_paths = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    hook = _load_hook()
    sys.stdout.write(render(hook.daedalus_root(), diff_paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
