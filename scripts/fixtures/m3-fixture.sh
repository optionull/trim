#!/bin/bash
# M3's and M4's .NET solution at $1: Orders.slnx with one console project, src/Orders.Api, in git. The chain writes its
# Program.cs with a build error before each check.
set -euo pipefail
D=$1
rm -rf "$D" && mkdir -p "$D/src/Orders.Api" && cd "$D"
cat > src/Orders.Api/Orders.Api.csproj <<'X'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
X
cat > Orders.slnx <<'X'
<Solution>
  <Folder Name="/src/">
    <Project Path="src/Orders.Api/Orders.Api.csproj" />
  </Folder>
</Solution>
X
printf 'Console.WriteLine("orders");\n' > src/Orders.Api/Program.cs
printf 'bin/\nobj/\n' > .gitignore
git init -q && git add -A && git -c user.email=a@b -c user.name=s -c commit.gpgsign=false commit -qm base
dotnet restore Orders.slnx -v q >/dev/null
