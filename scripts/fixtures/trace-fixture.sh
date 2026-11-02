#!/bin/bash
# A restored copy of the TraceShop fixture at $1.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$1" && cp -R $REPO/Tests/SillCoreTests/Fixtures/TraceShop "$1" && cd "$1" && dotnet restore TraceShop.slnx -v q >/dev/null
