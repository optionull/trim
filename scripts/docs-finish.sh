#!/usr/bin/env bash
# What both builds (scripts/docs.sh and the docs workflow) do after docs-builder: the Trim theme appended to the
# design system's stylesheet, the logo in the header, the landing page over the generated index.html and robots.txt.
# Needs a build with FEATURE_NAVIGATION_PREVIEW=true: without it the pages load no ds.css and this fails.
#
#   scripts/docs-finish.sh .artifacts/docs/html [path prefix]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: docs-finish.sh <docs-builder output dir> [path prefix]}"
prefix="${2:-}"

# The theme goes into the ds.css the pages actually load. Its name comes from docs-builder (plain ds.css with ?v=, or a
# hashed file), so read it from a built page. Before the landing page replaces index.html.
probe="$out/getting-started/index.html"
[[ -f "$probe" ]] || { echo "docs: $probe is missing, cannot find the design-system stylesheet" >&2; exit 1; }
href="$(grep -o 'href="[^"]*/_static/ds[^"/]*\.css[^"]*"' "$probe" | grep -v 'ds-layers' | head -n1 | sed 's/^href="//; s/"$//; s/?.*$//')" || true
if [[ -z "$href" ]]; then
  echo "docs: $probe loads no design-system ds.css; build with FEATURE_NAVIGATION_PREVIEW=true" >&2
  exit 1
fi
css="$out/_static/${href##*/_static/}"
[[ -f "$css" ]] || { echo "docs: $css (from $href) does not exist" >&2; exit 1; }
# An incremental docs-builder build keeps the previous ds.css, theme and all: cut it at the marker before appending.
marker="/* trim-docs.css: appended by scripts/docs-finish.sh */"
awk -v m="$marker" '$0 == m { exit } { print }' "$css" > "$css.tmp"
{ printf '%s\n' "$marker"; cat "$root/docs/trim-docs.css"; } >> "$css.tmp"
mv "$css.tmp" "$css"

# The header logo is the docset's branding.icon: see scripts/docs-pages.py.
logo="$(sed -n 's/^  icon:[[:space:]]*//p' "$root/docs/_docset.yml" | head -n1)"
[[ -n "$logo" ]] || { echo "docs: docs/_docset.yml has no branding icon: for the header logo" >&2; exit 1; }
python3 -I "$root/scripts/docs-pages.py" "$out" "$root/docs" "$prefix" "$logo"

cp "$root/docs/trim-landing.html" "$out/index.html"
cp "$root/docs/robots.txt" "$out/robots.txt"
echo "docs: finished $out (theme appended to ${css#"$out"/}, landing page applied)"
