#!/bin/bash
# The Razor check's solution at $1: a Blazor app, Orders.Web, in Orders.slnx, in git.
set -euo pipefail
D=$1
rm -rf "$D" && mkdir -p "$D" && cd "$D"
dotnet new blazor -o Orders.Web -n Orders.Web --no-https >/dev/null 2>&1
dotnet new sln -n Orders >/dev/null 2>&1
dotnet sln Orders.slnx add Orders.Web/Orders.Web.csproj >/dev/null 2>&1
(cd Orders.Web && dotnet build -nologo -v q >/dev/null 2>&1)
git init -q
