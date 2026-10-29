#!/bin/bash
set -euo pipefail
momo_repo="$(cd "$(dirname "$0")/../.." && pwd)"
momo_output="${1:?Provide a task-specific output directory}"
mkdir -p "$momo_output/modules" "$momo_output/module-cache"
momo_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun swiftc -emit-module -parse-as-library -module-name MoMoWeb -swift-version 6 \
  -target arm64-apple-ios18.0 -sdk "$momo_sdk" \
  -module-cache-path "$momo_output/module-cache" \
  "$momo_repo"/Packages/MoMoAgentWeb/Sources/MoMoWeb/*.swift \
  -emit-module-path "$momo_output/modules/MoMoWeb.swiftmodule"
xcrun swiftc -typecheck -module-name WebSettingsCompileCheck -swift-version 6 \
  -target arm64-apple-ios18.0 -sdk "$momo_sdk" \
  -module-cache-path "$momo_output/module-cache" -I "$momo_output/modules" \
  "$momo_repo/Apps/Shared/BrandPalette.swift" \
  "$momo_repo/Apps/iPhoneApp/SharedUI/PhoneTypography.swift" \
  "$momo_repo/Apps/iPhoneApp/SharedUI/PhonePageSurface.swift" \
  "$momo_repo/Apps/iPhoneApp/Features/Settings/WebSettingsView.swift"
