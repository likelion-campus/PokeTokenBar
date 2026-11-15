#!/usr/bin/env python3
"""Per-OS docs/screenshot gate for team releases (the fork's port of release.sh's asset rule).

  team_docs_check.py [--since TAG]
  exit 0 = pass (warnings printed), 2 = hard stop, 1 = usage / git error

Run from inside the repository. "Since" defaults to the last v* tag reachable from HEAD.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

# ---- data: path groups -------------------------------------------------------
P = "Sources/PokeTokenBar/"
MAC_PATHS = [P + "UI/", P + "Team/UI/", P + "Platform/Mac/", P + "PokeTokenBarApp.swift"]
WIN_PATHS = [P + "Platform/Windows/Popover/", P + "Platform/Windows/Plaza/",
             P + "Platform/Windows/WinTray*.swift", "Sources/CPlazaD2D/", "installer/"]
SHARED_PATHS = [P + "Team/Plaza/", P + "Popover/"]
WIN_ASSETS = "assets/windows/"
# group name -> (code paths, predicate on an asset path)
GROUPS = {
    "mac": (MAC_PATHS, lambda f: f.startswith("assets/") and not f.startswith(WIN_ASSETS)),
    "windows": (WIN_PATHS, lambda f: f.startswith(WIN_ASSETS)),
}
# a shared path counts for these groups (each needs its own new asset)
SHARED_FOR = ["mac", "windows"]
FEAT = re.compile(r"^(feat|feature)[(:!]")
# -------------------------------------------------------------------------------


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"team_docs_check: git {' '.join(args)} failed: {r.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return r.stdout


def feat_subjects(since, paths):
    out = git("log", "--format=%s", f"{since}..HEAD", "--", *paths)
    return [s for s in out.splitlines() if FEAT.match(s)]


def changed(since, diff_filter=None):
    cmd = ["diff", "--name-only"]
    if diff_filter:
        cmd.append(f"--diff-filter={diff_filter}")
    return git(*cmd, f"{since}..HEAD", "--", "assets").splitlines()


def paths_changed(since, paths):
    return bool(git("log", "--format=%h", f"{since}..HEAD", "--", *paths).strip())


def gate(since):
    stops, warns = [], []
    added = changed(since, "A")
    touched = changed(since)
    # (label, code paths, groups whose assets are required)
    areas = [(g, GROUPS[g][0], [g]) for g in GROUPS] + [("shared", SHARED_PATHS, SHARED_FOR)]
    for label, paths, needed in areas:
        feats = feat_subjects(since, paths)
        for g in needed:
            pred = GROUPS[g][1]
            if feats and not any(pred(f) for f in added):
                stops.append(f"{label} paths have feat commits but no new {g} asset was added "
                             f"({len(feats)}): " + "; ".join(feats))
            if paths_changed(since, paths) and not any(pred(f) for f in touched):
                warns.append(f"{label} paths changed since {since}; no {g} asset changed")
    return stops, warns


def shots_check(root):
    stops = []
    shots = root / WIN_ASSETS / "SHOTS.txt"
    pngs = {p.name for p in (root / WIN_ASSETS).glob("*.png")}
    listed = set()
    if not shots.exists():
        return [f"{WIN_ASSETS}SHOTS.txt is missing"] if pngs else []
    for n, line in enumerate(shots.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = [x.strip() for x in line.split(" | ")]
        if len(parts) != 4:
            stops.append(f"SHOTS.txt line {n}: expected 4 fields 'file | run | command | label'")
            continue
        name, _run, _cmd, label = parts
        listed.add(name)
        if not (root / WIN_ASSETS / name).exists():
            stops.append(f"SHOTS.txt line {n}: {name} does not exist")
        if "Windows CI runner" not in label:
            stops.append(f"SHOTS.txt line {n}: label of {name} lacks 'Windows CI runner'")
    for name in sorted(pngs - listed):
        stops.append(f"{WIN_ASSETS}{name} is not listed in SHOTS.txt")
    return stops


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--since")
    p.error = lambda m: (print(f"team_docs_check: {m}", file=sys.stderr), sys.exit(1))
    args = p.parse_args(argv)
    root = Path(git("rev-parse", "--show-toplevel").strip())
    since = args.since or git("describe", "--tags", "--match", "v*", "--abbrev=0").strip()
    stops, warns = gate(since)
    stops += shots_check(root)
    for w in warns:
        print(f"WARNING: {w}", file=sys.stderr)
    for s in stops:
        print(f"STOP: {s}", file=sys.stderr)
    if stops:
        print("team_docs_check: hard stop (exit 2). Add the capture, or record the judgement "
              "with another commit type.", file=sys.stderr)
        return 2
    print(f"team_docs_check: ok since {since}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
