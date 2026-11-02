#!/bin/bash
# A restored git copy of the TraceShop fixture at $1, with a second worktree at $1-feature.
set -euo pipefail
"$(dirname "$0")"/trace-fixture.sh "$1"
cd "$1" && printf 'bin/\nobj/\n' > .gitignore && git init -q && git add -A && git -c user.email=a@b -c user.name=s commit -qm base
rm -rf "$1-feature" && git worktree add -q "$1-feature"
