#!/usr/bin/env python3
"""Team release notes: validate (check) and fill (fill) the notes file.

  team_notes.py check --in NOTES                                  exit 0 / 1 with the reason
  team_notes.py fill  --in NOTES --version V --sha256 HEX --out OUT   exit 0 / 1
"""
import argparse
import re
import sys

SECTIONS = ["New", "Fixed", "Other", "Contributors"]
TOKENS = ["{{VERSION}}", "{{WINDOWS_SHA256}}"]
WINDOWS_LINES = ["**Windows Install:**", "**Windows Upgrade:**", "**Windows differences:**"]
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
# Template text that must be replaced by the release writer before any release. None today: the first version that
# installs updates in-app (v2.5.635) is written into the template; a future placeholder goes here.
PLACEHOLDERS = []


def strip_comments(text):
    return COMMENT.sub("", text)


def problems(text):
    """Return a list of reasons the notes are not releasable (empty = ok)."""
    text = strip_comments(text)
    found = []
    lines = text.splitlines()
    for name in SECTIONS:
        heads = [i for i, l in enumerate(lines) if l.strip() == f"## {name}"]
        if len(heads) != 1:
            found.append(f"section '## {name}' must appear exactly once (found {len(heads)})")
            continue
        body = []
        for l in lines[heads[0] + 1:]:
            if l.startswith("## ") or l.strip() == "---":
                break
            body.append(l)
        if not "".join(body).strip():
            found.append(f"section '## {name}' is empty (write 'None.' if nothing)")
    for marker in WINDOWS_LINES:
        n = sum(1 for l in lines if l.startswith(marker))
        if n != 1:
            found.append(f"line starting '{marker}' must appear exactly once (found {n})")
    for placeholder in PLACEHOLDERS:
        if placeholder in text:
            found.append(f"the template placeholder '{placeholder}' is still there: write the real text")
    for token in TOKENS:
        n = text.count(token)
        if n != 1:
            found.append(f"token {token} must appear exactly once (found {n})")
    return found


def cmd_check(args):
    found = problems(open(args.infile, encoding="utf-8").read())
    for f in found:
        print(f"team_notes: {f}", file=sys.stderr)
    return 1 if found else 0


def cmd_fill(args):
    if not re.fullmatch(r"[0-9a-fA-F]{64}", args.sha256):
        print("team_notes: --sha256 must be 64 hex characters", file=sys.stderr)
        return 1
    if not args.version.strip():
        print("team_notes: --version is empty", file=sys.stderr)
        return 1
    text = strip_comments(open(args.infile, encoding="utf-8").read())
    text = text.replace("{{VERSION}}", args.version).replace("{{WINDOWS_SHA256}}", args.sha256.lower())
    if "{{" in text:
        print("team_notes: leftover '{{' after fill; refusing", file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(re.sub(r"\n{3,}", "\n\n", text).strip() + "\n")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--in", dest="infile", required=True)
    f = sub.add_parser("fill")
    f.add_argument("--in", dest="infile", required=True)
    f.add_argument("--version", required=True)
    f.add_argument("--sha256", required=True)
    f.add_argument("--out", required=True)
    args = p.parse_args(argv)
    return {"check": cmd_check, "fill": cmd_fill}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
