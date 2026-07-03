#!/usr/bin/env bash
set -euo pipefail

swift build
swift test
swift build --package-path libs/swift
swift test --package-path libs/swift
node docs/site/build.mjs
