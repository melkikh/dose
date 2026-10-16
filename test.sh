#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/module-cache
swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" Sources/Core.swift Tests/CoreTests.swift -o .build/core-tests
.build/core-tests
