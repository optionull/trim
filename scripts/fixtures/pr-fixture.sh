#!/bin/bash
# A repository at $1 on branch tax-once: one commit pushed to its remote ($1.git), one not; and $1.gh, a stand-in gh
# that logs its arguments to $1.gh.log and answers `pr list` with pull request #12 (two checks failing, changes
# requested, conflicting).
set -euo pipefail
D=$1
rm -rf "$D" "$D.git" "$D.gh" "$D.gh.log"
git init -q --bare "$D.git"
mkdir -p "$D" && cd "$D"
g() { git -c user.email=a@b -c user.name=s -c commit.gpgsign=false "$@"; }
g init -q -b main
echo one > a.txt && g add a.txt && g commit -qm one
g remote add origin "$D.git" && g push -q origin main
g checkout -qb tax-once && echo two >> a.txt && g commit -qam two && g push -q -u origin tax-once 2>/dev/null
echo three >> a.txt && g commit -qam three
cat > "$D.gh" <<SH
#!/bin/bash
echo "\$*" >> "$D.gh.log"
[ "\$1 \$2" = "pr list" ] || exit 1
cat <<'JSON'
[{"number": 12, "title": "Round the tax once", "url": "https://example.test/pr/12", "state": "OPEN",
  "isDraft": false, "baseRefName": "main", "mergeable": "CONFLICTING", "reviewDecision": "CHANGES_REQUESTED",
  "updatedAt": "2026-10-25T12:00:00Z",
  "statusCheckRollup": [
    {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "FAILURE",
     "detailsUrl": "https://example.test/run/1"},
    {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "FAILURE"}],
  "latestReviews": [{"author": {"login": "ana"}, "state": "CHANGES_REQUESTED", "body": "Round in one place.",
                     "submittedAt": "2026-10-25T11:00:00Z"}],
  "comments": []}]
JSON
SH
chmod +x "$D.gh"
