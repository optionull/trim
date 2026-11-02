#!/bin/bash
# The since-you-last-looked check's checkout at $1: 24 files in three areas, committed; then 23 of them changed, and a
# leaving an hour ago noted in .sill/looked.json with the worktree as it was committed (what is new is since then).
set -euo pipefail
D=$1
rm -rf "$D" && mkdir -p "$D/src/Shop" "$D/tests/Shop.Tests" && cd "$D"
for i in $(seq 1 12); do printf 'class A%s {}\n' "$i" > "src/Shop/A$i.cs"; done
for i in $(seq 1 10); do printf 'class T%s {}\n' "$i" > "tests/Shop.Tests/T$i.cs"; done
printf '# Shop\n' > README.md
printf 'notes\n' > NOTES.md
git init -q && git add -A && git -c user.email=a@b -c user.name=s -c commit.gpgsign=false commit -qm base
TREE=$(git rev-parse 'HEAD^{tree}')
ROOT=$(git rev-parse --show-toplevel)
for i in $(seq 1 12); do printf 'class A%s { int x; }\n' "$i" > "src/Shop/A$i.cs"; done
for i in $(seq 1 10); do printf 'class T%s { int y; }\n' "$i" > "tests/Shop.Tests/T$i.cs"; done
printf '# Shop\n\nNow with x and y.\n' > README.md
mkdir -p .sill && printf '.sill/\n' >> .git/info/exclude
# JSONEncoder's dates: seconds since 2001-01-01.
AT=$(( $(date +%s) - 3600 - 978307200 ))
printf '{"%s":{"left":{"at":%s,"tree":"%s"}}}\n' "$ROOT" "$AT" "$TREE" > .sill/looked.json
