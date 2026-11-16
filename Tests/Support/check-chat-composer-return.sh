#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/momo-composer-return-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$scratch/module-cache" \
    Apps/Shared/BrandPalette.swift Apps/ClientUI/ClientTypography.swift Apps/ClientUI/ComposerSurface.swift \
    Tests/Support/chat-composer-return-smoke.swift -o "$scratch/chat-composer-return-smoke"
"$scratch/chat-composer-return-smoke"
