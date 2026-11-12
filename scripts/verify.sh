#!/bin/bash
# Lint, tests and every self-check of sill; stops at the first failure (mise run verify). The fixtures are in
# scripts/fixtures; a check's copies of them go to /tmp. Needs a dev build of heed for the m5 check.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
F=$REPO/scripts/fixtures
LOGS=$(mktemp -d /tmp/sill-verify.XXXX)
SKIPPED=""
mise run fmt >/dev/null 2>&1
# Lint's own status is not used: under pipefail a failing lint would make the test false and pass.
lint=$(mise run lint 2>&1 || true)
if echo "$lint" | grep -E "error|warning"; then echo "LINT FAILED"; exit 1; fi
mise run test > $LOGS/test.log 2>&1 || { tail -30 $LOGS/test.log; exit 1; }
passed=$(grep -c "Test run .*passed" $LOGS/test.log || true)
grep "Test run" $LOGS/test.log
[ "$passed" -ge 4 ] || { echo "only $passed suites passed"; exit 1; }
mise run build 2>&1 | tail -1
S=$PWD/build/Sill.app/Contents/MacOS/Sill
H=~/code/wt/heed/control-socket/build/Heed.app/Contents/Helpers/heed
run() { # name, then env assignments; the check must print "passed". A timeout on the app itself (alarm, then exec):
  # nothing of it outlives the run.
  local name=$1; shift
  local out; out=$(env "$@" perl -e 'alarm 900; exec @ARGV' "$S" 2>&1 | grep -E "^ok|^sill check" || true)
  echo "$out" | grep "^sill check" || true
  echo "$out" | grep -qE "^sill check( \(.*\))?: passed$" || { echo "$out"; echo "CHECK $name FAILED"; exit 1; }
}
run 1 SILL_CHECK=1 HEED_CONTROL=/tmp/no-heed.sock
run chrome SILL_CHECK=chrome HEED_CONTROL=/tmp/no-heed.sock
$F/m3-fixture.sh /tmp/sill-m3
cd /tmp/sill-m3
printf 'var order = 1;\nConsole.WriteLine(order.Lines);\n' > src/Orders.Api/Program.cs
run m3 SILL_CHECK=m3 SILL_CWD=/tmp/sill-m3 HEED_CONTROL=/tmp/no-heed.sock
printf 'var order = 1;\nConsole.WriteLine(order.Lines);\n' > src/Orders.Api/Program.cs
run m4 SILL_CHECK=m4 SILL_CWD=/tmp/sill-m3 SILL_MCP_ALLOW=build SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock
# m5's heed: a dev build in its own home, its claude a stand-in that logs what it is given. Without the build the check
# is skipped, and says so.
if [ -x "$H" ]; then
  pkill -f "control-socket/build/Heed.app/Contents/MacOS/Heed" || true
  (mkdir -p /tmp/heedlive && cd /tmp/heedlive && CFFIXED_USER_HOME=/tmp/heedlive/home XDG_CONFIG_HOME=/tmp/heedlive/config nohup ~/code/wt/heed/control-socket/build/Heed.app/Contents/MacOS/Heed </dev/null >/tmp/heedlive/heed.log 2>&1 &)
  for i in $(seq 1 20); do HEED_CONTROL="/tmp/heedlive/home/Library/Application Support/Heed/control.sock" "$H" sessions >/dev/null 2>&1 && break; /bin/sleep 1; done
  W=$(mktemp -d /tmp/sill-m5.XXXX)
  printf 'var order = 1;\nConsole.WriteLine(order.Lines);\n' > "$W/Program.cs"
  rm -f /tmp/heedlive/agent.log
  cd "$W"
  run m5 SILL_CHECK=m5 SILL_CWD="$W" "HEED_CONTROL=/tmp/heedlive/home/Library/Application Support/Heed/control.sock" \
    SILL_CHECK_AGENT_LOG=/tmp/heedlive/agent.log SILL_CHECK_HEED="$H" SILL_CHECK_SHOT=/tmp/sill-m5.png
else
  echo "SKIPPED m5: no heed dev build at ~/code/wt/heed/control-socket"
  SKIPPED="${SKIPPED:+$SKIPPED, }m5"
fi
rm -rf /tmp/sill-m6 && cp -R $REPO/Tests/SillSidecarTests/Fixtures/Sample /tmp/sill-m6
cd /tmp/sill-m6
run m6 SILL_OFFSCREEN=1 SILL_CHECK=m6 SILL_CWD=/tmp/sill-m6 SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock SILL_CHECK_SHOT=/tmp/sill-m6.png
$F/razor-fixture.sh /tmp/sill-razor
cd /tmp/sill-razor
run razor SILL_OFFSCREEN=1 SILL_CHECK=razor SILL_CWD=/tmp/sill-razor HEED_CONTROL=/tmp/no-heed.sock
rm -rf /tmp/sill-solution && cp -R $REPO/Tests/SillCoreTests/Fixtures/Solution /tmp/sill-solution
(cd /tmp/sill-solution && git init -q && git add -A && git -c user.email=a@b -c user.name=sill commit -qm fixture)
cd /tmp/sill-solution
run solution SILL_OFFSCREEN=1 SILL_CHECK=solution SILL_CWD=/tmp/sill-solution HEED_CONTROL=/tmp/no-heed.sock SILL_CHECK_SHOT=/tmp/sill-solution.png
rm -rf /tmp/sill-m8 && cp -R $REPO/Tests/SillSidecarTests/Fixtures/Sample /tmp/sill-m8
cd /tmp/sill-m8
run m8 SILL_OFFSCREEN=1 SILL_CHECK=m8 SILL_CWD=/tmp/sill-m8 HEED_CONTROL=/tmp/no-heed.sock SILL_CHECK_SHOT=/tmp/sill-m8.png
rm -rf /tmp/sill-debug && cp -R $REPO/Tests/SillSidecarTests/Fixtures/Debuggee /tmp/sill-debug
cd /tmp/sill-debug
run debug SILL_OFFSCREEN=1 SILL_CHECK=debug SILL_CWD=/tmp/sill-debug HEED_CONTROL=/tmp/no-heed.sock SILL_CHECK_SHOT=/tmp/sill-debug.png
rm -rf /tmp/sill-agentdebug && mkdir /tmp/sill-agentdebug && cp -R $REPO/Tests/SillSidecarTests/Fixtures/Debuggee $REPO/Tests/SillSidecarTests/Fixtures/Sample /tmp/sill-agentdebug/
cd /tmp/sill-agentdebug
run agentdebug SILL_OFFSCREEN=1 SILL_CHECK=agentdebug SILL_CWD=/tmp/sill-agentdebug SILL_MCP_ALLOW=debug,profile HEED_CONTROL=/tmp/no-heed.sock
rm -rf /tmp/sill-review && mkdir /tmp/sill-review && (cd /tmp/sill-review && seq -f "line %g" 1 20 > a.txt && echo keep > b.txt && git init -q && git add -A && git -c user.email=a@b -c user.name=s commit -qm base)
cd /tmp/sill-review
run review SILL_OFFSCREEN=1 SILL_CHECK=review SILL_CWD=/tmp/sill-review SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock
rm -rf /tmp/sill-walk /tmp/sill-walk-home && mkdir -p /tmp/sill-walk-home && cp -R $REPO/Tests/SillSidecarTests/Fixtures/Debuggee /tmp/sill-walk && (cd /tmp/sill-walk && git init -q && git add -A && git -c user.email=a@b -c user.name=s commit -qm base)
cd /tmp/sill-walk
run walk SILL_OFFSCREEN=1 SILL_CHECK=walk SILL_CWD=/tmp/sill-walk SILL_AGENT=echo CFFIXED_USER_HOME=/tmp/sill-walk-home HEED_CONTROL=/tmp/no-heed.sock
$F/basket-fixture.sh /tmp/sill-config
(cd /tmp/sill-config && run config SILL_OFFSCREEN=1 SILL_CHECK=config SILL_CHECK_CONFIG=1 SILL_CWD=/tmp/sill-config HEED_CONTROL=/tmp/no-heed.sock)
$F/compat-fixture.sh /tmp/sill-compat-xdg
(cd /tmp && run compat SILL_OFFSCREEN=1 SILL_CHECK=compat SILL_CHECK_USER=1 SILL_NVIM_CONFIG=1 XDG_CONFIG_HOME=/tmp/sill-compat-xdg SILL_CWD=/tmp HEED_CONTROL=/tmp/no-heed.sock)
$F/run-fixture.sh /tmp/sill-run
(cd /tmp/sill-run && run run SILL_CHECK=run SILL_CWD=/tmp/sill-run HEED_CONTROL=/tmp/no-heed.sock)
$F/home-fixture.sh /tmp/sill-home
(cd /tmp && run home SILL_HOME=1 SILL_CHECK=home SILL_OFFSCREEN=1 SILL_ROOTS=/tmp/sill-home/roots SILL_TRANSCRIPTS=/tmp/sill-home/transcripts SILL_GH=/tmp/sill-home/gh HEED_CONTROL=/tmp/no-heed.sock)
$F/looked-fixture.sh /tmp/sill-looked
(cd /tmp/sill-looked && run looked SILL_OFFSCREEN=1 SILL_CHECK=looked SILL_CWD=/tmp/sill-looked HEED_CONTROL=/tmp/no-heed.sock)
$F/pr-fixture.sh /tmp/sill-pr
(cd /tmp/sill-pr && run pr SILL_OFFSCREEN=1 SILL_CHECK=pr SILL_CWD=/tmp/sill-pr SILL_GH=/tmp/sill-pr.gh SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock)
$F/basket-fixture.sh /tmp/sill-hooks
(cd /tmp/sill-hooks && run hooks SILL_OFFSCREEN=1 SILL_CHECK=hooks SILL_CWD=/tmp/sill-hooks SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock)
$F/basket-fixture.sh /tmp/sill-investigate && rm -rf /tmp/sill-investigate-home && mkdir -p /tmp/sill-investigate-home
(cd /tmp/sill-investigate && run investigate SILL_OFFSCREEN=1 SILL_CHECK=investigate SILL_CWD=/tmp/sill-investigate SILL_AGENT=echo CFFIXED_USER_HOME=/tmp/sill-investigate-home HEED_CONTROL=/tmp/no-heed.sock)
$F/basket-fixture.sh /tmp/sill-basket
(cd /tmp/sill-basket && run basket SILL_OFFSCREEN=1 SILL_CHECK=basket SILL_CWD=/tmp/sill-basket SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock)
$F/trace-fixture.sh /tmp/sill-trace
(cd /tmp/sill-trace && run trace SILL_OFFSCREEN=1 SILL_CHECK=trace SILL_CWD=/tmp/sill-trace SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock)
$F/map-fixture.sh /tmp/sill-map
(cd /tmp/sill-map && run map SILL_OFFSCREEN=1 SILL_CHECK=map SILL_CWD=/tmp/sill-map SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock)
R=$(mktemp -d /tmp/sill-refs.XXXX) && mkdir "$R/src" && seq -f "line %g" 1 20 > "$R/src/a.txt"
(cd "$R" && run refs SILL_OFFSCREEN=1 SILL_CHECK=refs SILL_CWD="$R" HEED_CONTROL=/tmp/no-heed.sock)
rm -rf /tmp/sill-follow && mkdir /tmp/sill-follow && (cd /tmp/sill-follow && seq -f "line %g" 1 20 > a.txt && echo keep > b.txt && echo "*.log" > .gitignore && git init -q && git add -A && git -c user.email=a@b -c user.name=s commit -qm base)
cd /tmp/sill-follow
run follow SILL_OFFSCREEN=1 SILL_CHECK=follow SILL_CWD=/tmp/sill-follow HEED_CONTROL=/tmp/no-heed.sock
rm -rf /tmp/sill-ask && cp -R $REPO/Tests/SillSidecarTests/Fixtures/Debuggee /tmp/sill-ask
cd /tmp/sill-ask
run ask SILL_OFFSCREEN=1 SILL_CHECK=ask SILL_CWD=/tmp/sill-ask SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock
rm -rf /tmp/sill-telemetry && cp -R $REPO/Tests/SillSidecarTests/Fixtures/Shop /tmp/sill-telemetry && rm -rf /tmp/sill-telemetry/bin /tmp/sill-telemetry/obj && (cd /tmp/sill-telemetry && dotnet build -nologo -v q >/dev/null)
cd /tmp/sill-telemetry
run telemetry SILL_OFFSCREEN=1 SILL_CHECK=telemetry SILL_CWD=/tmp/sill-telemetry HEED_CONTROL=/tmp/no-heed.sock
rm -rf /tmp/sill-reviewwalk && cp -R $REPO/Tests/SillSidecarTests/Fixtures/Orders /tmp/sill-reviewwalk && (cd /tmp/sill-reviewwalk && git init -q && git add -A && git -c user.email=a@b -c user.name=s commit -qm base)
cd /tmp/sill-reviewwalk
run reviewwalk SILL_OFFSCREEN=1 SILL_CHECK=reviewwalk SILL_CWD=/tmp/sill-reviewwalk SILL_AGENT=echo HEED_CONTROL=/tmp/no-heed.sock
rm -rf /tmp/sill-polyglot && cp -R $REPO/Tests/SillCoreTests/Fixtures/Polyglot /tmp/sill-polyglot
cd /tmp/sill-polyglot
run servers SILL_OFFSCREEN=1 SILL_CHECK=servers SILL_CWD=/tmp/sill-polyglot HEED_CONTROL=/tmp/no-heed.sock
for sample in Rust Swift; do
  rm -rf /tmp/sill-m7-$sample && cp -R $REPO/Tests/SillCoreTests/Fixtures/${sample}Sample /tmp/sill-m7-$sample
  cd /tmp/sill-m7-$sample
  run "m7 $sample" SILL_OFFSCREEN=1 SILL_CHECK=m7 SILL_CWD=/tmp/sill-m7-$sample HEED_CONTROL=/tmp/no-heed.sock SILL_CHECK_SHOT=/tmp/sill-m7-$sample.png
done
rm -rf /tmp/sill-settings && mkdir /tmp/sill-settings && cd /tmp/sill-settings
run settings SILL_OFFSCREEN=1 SILL_CHECK=settings SILL_SETTINGS=/tmp/sill-settings/settings.toml SILL_CWD=/tmp/sill-settings HEED_CONTROL=/tmp/no-heed.sock SILL_CHECK_SHOT=/tmp/sill-settings.png
bash $REPO/scripts/mergetool-check.sh | tail -1 | grep -q "MERGETOOL VERIFIED" || { echo "CHECK mergetool FAILED"; exit 1; }
echo "sill check (mergetool): passed"
out=$(cd /tmp && perl -e 'alarm 120; exec @ARGV or die' env SILL_SHELL_CHECK=1 "$REPO/build/Sill Shell.app/Contents/MacOS/SillShell" 2>&1 | grep -E "^shell check" || true)
echo "$out" | grep -q "^shell check: passed$" || { echo "$out"; echo "CHECK shell FAILED"; exit 1; }
echo "sill check (shell): passed"
if [ -d ~/Projects/docs-builder ]; then
  # A clone of its own, never the owner's working copy: made once, reset to their HEAD each run, restored when new.
  D=/tmp/sill-docs-builder
  # A clone /tmp's cleanup has gutted is made again.
  git -C "$D" rev-parse --git-dir >/dev/null 2>&1 || rm -rf "$D"
  if [ ! -d "$D/.git" ]; then git clone -q --local ~/Projects/docs-builder "$D"; fi
  git -C "$D" fetch -q ~/Projects/docs-builder HEAD && git -C "$D" reset -q --hard FETCH_HEAD && git -C "$D" clean -qfdx -e obj -e bin -e .artifacts
  # Its global.json names the SDK it needs: without it installed the check cannot run, and says so.
  if (cd "$D" && dotnet --version >/dev/null 2>&1); then
    if [ ! -d "$D/src/Elastic.Markdown/obj" ]; then (cd "$D" && dotnet restore docs-builder.slnx -v q >/dev/null); fi
    cd "$D"
    run project SILL_CHECK=project SILL_CWD="$D" HEED_CONTROL=/tmp/no-heed.sock
  else
    echo "SKIPPED project: docs-builder's global.json asks for a .NET SDK that is not installed"
    SKIPPED="${SKIPPED:+$SKIPPED, }project"
  fi
fi
pkill -f "control-socket/build/Heed.app/Contents/MacOS/Heed" || true
echo "ALL VERIFIED${SKIPPED:+ (skipped: $SKIPPED)}"
