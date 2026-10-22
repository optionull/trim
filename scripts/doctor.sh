#!/usr/bin/env bash
# Report what is missing for a full build. Exits non-zero if something required is absent.
set -uo pipefail
ok=1
check() { if eval "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "MISS  $1  ->  $3"; ok=0; fi; }
check "Xcode selected" "xcode-select -p | grep -q 'Xcode'" "sudo xcode-select --switch /Applications/Xcode.app"
check "Xcode licence accepted" "xcrun --find swiftc" "sudo xcodebuild -license accept"
check "Swift 6.4+" "swift --version 2>&1 | grep -qE 'Swift version (6\.[4-9]|[7-9])'" "update Xcode"
check "Metal toolchain" "xcrun --find metal" "xcodebuild -downloadComponent MetalToolchain"
check "zig 0.16" "zig version | grep -q '^0.16'" "mise install"
check "nvim 0.12+" "nvim --version | head -1 | grep -qE 'NVIM v0\.(1[2-9]|[2-9][0-9])'" "mise use -g neovim@latest"
[ "$ok" = 1 ]
