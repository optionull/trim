#!/bin/bash
# A git copy of the MapShop fixture at $1: Pricing.cs changed in three commits, Program.cs in one.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$1" && cp -R $REPO/Tests/SillCoreTests/Fixtures/MapShop "$1" && cd "$1"
g() { git -c user.email=a@b -c user.name=s "$@"; }
git init -q && git add -A && g commit -qm base
for rate in 3.6 3.7; do
  sed -i '' "s/count \* [0-9.]*m/count * ${rate}m/" src/Shop.Core/Pricing.cs && g commit -qam "rate $rate"
done
