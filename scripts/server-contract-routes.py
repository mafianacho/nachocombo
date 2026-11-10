#!/usr/bin/env python3
"""Lists the REST routes of a nacho-server checkout (spec/*.tsp) as "METHOD /path" lines.

usage: scripts/server-contract-routes.py <nacho-server repo> [git ref, default origin/main]
Reads the spec with `git show <ref>:spec/<file>` (no checkout, nothing written there). Used to refresh
Tests/NachoComboCoreTests/PetServerContract.swift; scripts/check-server-contract.sh diffs the two.
"""
import re
import subprocess
import sys


def show(repo, ref, path):
    return subprocess.run(["git", "-C", repo, "show", f"{ref}:{path}"], check=True, capture_output=True, text=True).stdout


def routes(text):
    out = []
    prefix = ""
    depth = 0
    iface_prefix = None
    pending_route = None
    pending_method = None
    # Strip comments so doc text with "@route" never counts.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    for tok in re.finditer(r'@route\("([^"]*)"\)|@(get|post|put|patch|delete)\b|\binterface\s+\w+[^{]*\{|\{|\}|\b[a-zA-Z_]\w*\s*\(', text):
        t = tok.group(0)
        if tok.group(1) is not None:
            pending_route = tok.group(1)
        elif tok.group(2):
            pending_method = tok.group(2).upper()
        elif t.startswith("interface"):
            iface_prefix = pending_route or ""
            pending_route = None
            depth = 1
            prefix = iface_prefix
        elif t == "{":
            if depth:
                depth += 1
        elif t == "}":
            if depth:
                depth -= 1
                if depth == 0:
                    prefix = ""
                    iface_prefix = None
        elif depth == 1 and pending_method:
            out.append(f"{pending_method} {prefix}{pending_route or ''}")
            pending_method = None
            pending_route = None
    return out


def main():
    repo = sys.argv[1]
    ref = sys.argv[2] if len(sys.argv) > 2 else "origin/main"
    files = subprocess.run(["git", "-C", repo, "ls-tree", "--name-only", ref, "spec/"], check=True, capture_output=True, text=True).stdout.split()
    all_routes = set()
    for f in files:
        if f.endswith(".tsp"):
            all_routes.update(routes(show(repo, ref, f)))
    for r in sorted(all_routes):
        print(r)


if __name__ == "__main__":
    main()
