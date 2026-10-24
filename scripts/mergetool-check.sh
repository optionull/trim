#!/bin/bash
# sill as git's real mergetool, over the kinds of conflict git writes. For each kind, three runs:
#   theirs: every conflict taken as theirs and saved: git must see the file resolved, its text what
#           `git merge-file --theirs` makes of the same three versions;
#   leave:  saved with the conflicts still in: sill exits nonzero and git keeps the file unmerged;
#   cq:     resolved and saved, then :cquit: nonzero from nvim alone, unmerged.
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)/build/Sill.app/Contents/MacOS/Sill
ROOT=$(mktemp -d /tmp/sill-mergetool.XXXX)
failed=0

# make <dir> <style> <base> <ours> <theirs>: a repo with f.txt conflicting between main and theirs.
make() {
  local dir=$1 style=$2
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir"
  git init -q -b main
  git config user.email a@b; git config user.name sill
  git config merge.conflictStyle "$style"
  git config core.autocrlf false
  printf '%b' "$3" > f.txt; git add f.txt; git commit -qm base
  git checkout -qb theirs; printf '%b' "$5" > f.txt; git commit -qam theirs
  git checkout -q main; printf '%b' "$4" > f.txt; git commit -qam ours
  git merge -q theirs >/dev/null 2>&1 || true
  git show :1:f.txt > ../base.txt; git show :2:f.txt > ../ours.txt; git show :3:f.txt > ../theirs.txt
  git merge-file -p --theirs ../ours.txt ../base.txt ../theirs.txt > ../expected.txt || true
}

run() { # kind, style, mode, base, ours, theirs
  local kind=$1 style=$2 mode=$3
  make "$ROOT/$kind-$style-$mode/repo" "$style" "$4" "$5" "$6"
  git config mergetool.sill.cmd \
    "SILL_OFFSCREEN=1 SILL_CHECK=merge SILL_MERGE=$mode HEED_CONTROL=/tmp/no-heed.sock perl -e 'alarm 120; exec @ARGV' '$S' merge \"\$LOCAL\" \"\$BASE\" \"\$REMOTE\" \"\$MERGED\""
  git config mergetool.sill.trustExitCode true
  git config mergetool.keepBackup false
  local out; out=$(git mergetool --tool sill --no-prompt f.txt 2>&1) || true
  local unmerged; unmerged=$(git diff --name-only --diff-filter=U)
  local verdict=ok
  case $mode in
    theirs)
      [ -z "$unmerged" ] || verdict="still unmerged"
      cmp -s f.txt ../expected.txt || verdict="$verdict; text differs: $(diff ../expected.txt f.txt | head -5 | tr '\n' '|' || true)"
      ;;
    leave|cq)
      [ "$unmerged" = f.txt ] || verdict="git took it as resolved"
      ;;
  esac
  if [ "$verdict" = ok ]; then
    echo "ok    $kind ($style) $mode"
  else
    echo "FAIL  $kind ($style) $mode: $verdict"
    echo "$out" | tail -5 | sed 's/^/      /'
    failed=1
  fi
}

kinds() { # style, mode
  run content "$1" "$2" 'a\nb\nc\nd\ne\n' 'a\nB ours\nc\nd\ne\n' 'a\nB theirs\nc\nd\ne\n'
  run edges "$1" "$2" 'first\nm1\nm2\nm3\nm4\nlast\n' 'FIRST ours\nm1\nm2\nm3\nm4\nLAST ours\n' 'FIRST theirs\nm1\nm2\nm3\nm4\nLAST theirs\n'
  run adjacent "$1" "$2" 'a\nb\nc\nd\ne\nf\ng\n' 'a\nB1\nc\nD1\ne\nf\ng\n' 'a\nB2\nc\nD2\ne\nf\nG2\n'
  run crlf "$1" "$2" 'a\r\nb\r\nc\r\n' 'a\r\nB ours\r\nc\r\n' 'a\r\nB theirs\r\nc\r\n'
  run headings "$1" "$2" 'Title\n========\nx\n' 'Title\n========\nx ours\n' 'Title\n========\nx theirs\n'
  run underline "$1" "$2" 'a\nb\nc\n' 'a\nb ours\nc\n' 'a\nTitle\n========\nb theirs\nc\n'
  run deleted "$1" "$2" 'a\nb\nc\nd\n' 'a\nd\n' 'a\nB theirs\nc\nd\n'
}

# git difftool --trust-exit-code: :qa is 0, :cquit is nonzero, and git passes it on.
difftool() { # mode, expected status
  cd "$ROOT"; rm -rf diff; mkdir diff; cd diff; git init -q -b main; git config user.email a@b; git config user.name sill
  printf 'a\nb\n' > f.txt; git add f.txt; git commit -qm one; printf 'a\nB\n' > f.txt
  git config difftool.sill.cmd \
    "SILL_OFFSCREEN=1 SILL_CHECK=merge SILL_MERGE=$1 HEED_CONTROL=/tmp/no-heed.sock perl -e 'alarm 120; exec @ARGV' '$S' diff \"\$LOCAL\" \"\$REMOTE\""
  local status=0; git difftool --tool sill --no-prompt --trust-exit-code >/dev/null 2>&1 || status=$?
  if { [ "$2" = 0 ] && [ $status = 0 ]; } || { [ "$2" != 0 ] && [ $status != 0 ]; }; then
    echo "ok    difftool $1: status $status"
  else
    echo "FAIL  difftool $1: status $status"; failed=1
  fi
}
difftool leave 0
difftool cq 1

for style in merge diff3 zdiff3; do
  kinds "$style" theirs
done
kinds merge leave
kinds diff3 cq
rm -rf "$ROOT"
[ $failed = 0 ] && echo "MERGETOOL VERIFIED" || { echo "MERGETOOL FAILED"; exit 1; }
