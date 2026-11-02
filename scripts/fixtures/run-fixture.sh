#!/bin/bash
# The Run check's checkout at $1: a Swift package with one executable, hello, which prints sill-run-hello and its
# arguments; built once here so the check's runs are quick.
set -euo pipefail
D=$1
rm -rf "$D" && mkdir -p "$D/Sources/hello" && cd "$D"
cat > Package.swift <<'X'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "hello", targets: [.executableTarget(name: "hello")])
X
printf 'print((["sill-run-hello"] + CommandLine.arguments.dropFirst()).joined(separator: " "))\n' > Sources/hello/main.swift
printf '.build/\n' > .gitignore
git init -q && git add -A && git -c user.email=a@b -c user.name=s -c commit.gpgsign=false commit -qm base
swift build -q >/dev/null 2>&1
