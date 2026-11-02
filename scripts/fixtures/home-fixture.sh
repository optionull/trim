#!/bin/bash
# Home's fixture at $1: roots/alpha (a handoff for its worktree and a review walkthrough in its .sill), its worktree
# alpha-feature outside the roots with a change and an agent working in its transcript, and roots/group/beta, old.
set -euo pipefail
D=$1
rm -rf "$D" && mkdir -p "$D/roots/group" "$D/transcripts"
g() { git -c user.email=a@b -c user.name=s -c commit.gpgsign=false "$@"; }
for r in alpha group/beta; do
  mkdir -p "$D/roots/$r" && cd "$D/roots/$r" && g init -q -b main && echo one > a.txt && g add a.txt
  GIT_COMMITTER_DATE="2020-01-01T00:00:00" GIT_AUTHOR_DATE="2020-01-01T00:00:00" g commit -qm one
done
cd "$D/roots/alpha" && g worktree add -q -b feature "$D/alpha-feature" && echo two > "$D/alpha-feature/a.txt"
touch -t 202001010000 "$D/roots/group/beta/a.txt" "$D/roots/alpha/a.txt"
F=$(cd "$D/alpha-feature" && pwd -P)
mkdir -p "$D/roots/alpha/.sill/handoffs" "$D/roots/alpha/.sill/reviews/1"
printf -- '---\ntitle: The tax, once\nworktree: %s\n---\nRounding moved to Pricing.\n' "$F" > "$D/roots/alpha/.sill/handoffs/tax.walk.md"
printf -- '---\ntitle: A review\n---\nWhat changed.\n' > "$D/roots/alpha/.sill/reviews/1/review.walk.md"
touch -t 202001020000 "$D/roots/alpha/.sill/reviews/1/review.walk.md"
T="$D/transcripts/$(printf '%s' "$F" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$T"
printf '%s\n%s\n' '{"type":"user","message":{"role":"user","content":"Round the tax once"}}' \
  '{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}' > "$T/session.jsonl"
