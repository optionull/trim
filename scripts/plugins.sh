#!/usr/bin/env bash
# Vendor/plugins: the nvim plugins Frame bundles (scripts/plugins.txt), each at a pinned tag whose commit is checked, with
# only what nvim loads kept (lua, colors, plugin, after, doc and the licence). No package manager at run time and no network
# after this: the app carries them.
set -euo pipefail
shopt -s nocaseglob nullglob
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Vendor/plugins"
mkdir -p "$out"
while read -r name repo tag commit; do
  case "$name" in ''|\#*) continue ;; esac
  if [ -f "$out/$name/.commit" ] && [ "$(cat "$out/$name/.commit")" = "$commit" ]; then
    echo "plugins: $name is $tag"
    continue
  fi
  # Cloned into a folder of its own; nothing in it is run, only copied.
  work="$(mktemp -d)"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "https://github.com/$repo.git" "$work/src"
  actual="$(git -C "$work/src" rev-parse HEAD)"
  if [ "$actual" != "$commit" ]; then
    echo "plugins: $name $tag is $actual, not the pinned $commit" >&2
    rm -rf "$work"
    exit 1
  fi
  rm -rf "$out/$name"
  mkdir -p "$out/$name"
  for keep in lua colors plugin after doc ftplugin syntax; do
    [ -d "$work/src/$keep" ] && cp -R "$work/src/$keep" "$out/$name/$keep"
  done
  for licence in "$work"/src/LICENSE* "$work"/src/LICENCE* "$work"/src/COPYING*; do
    [ -f "$licence" ] && cp "$licence" "$out/$name/"
  done
  echo "$commit" >"$out/$name/.commit"
  echo "$tag" >"$out/$name/.tag"
  rm -rf "$work"
  echo "plugins: $name is $tag"
done <"$root/scripts/plugins.txt"
