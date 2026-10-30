#!/bin/bash
set -euo pipefail
momo_repo="$(cd "$(dirname "$0")/../.." && pwd)"
momo_output="${1:?Provide a task-specific output directory}"
mkdir -p "$momo_output"
momo_output="$(cd "$momo_output" && pwd)"
momo_package="$momo_repo/Tools/HealthContextChecks"
momo_build="$momo_output/native-build"
swift test --package-path "$momo_package" --scratch-path "$momo_build" --no-parallel -j 2
momo_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
swift build --package-path "$momo_package" --scratch-path "$momo_build" \
  --triple arm64-apple-ios18.0 --sdk "$momo_sdk" --target PhoneHealthChecks -j 2
momo_binary="$(swift build --package-path "$momo_package" --scratch-path "$momo_build" \
  --triple arm64-apple-ios18.0 --sdk "$momo_sdk" --show-bin-path)"
xcrun swiftc -typecheck -module-name HealthSettingsCompileCheck -swift-version 6 \
  -target arm64-apple-ios18.0 -sdk "$momo_sdk" \
  -module-cache-path "$momo_output/module-cache" -I "$momo_binary/Modules" -I "$momo_binary" -F "$momo_binary/PackageFrameworks" \
  -Xcc "-fmodule-map-file=$momo_package/Sources/CSQLite/module.modulemap" \
  "$momo_repo/Apps/Shared/BrandPalette.swift" \
  "$momo_repo/Apps/iPhoneApp/SharedUI/PhoneTypography.swift" \
  "$momo_repo/Apps/iPhoneApp/SharedUI/PhonePageSurface.swift" \
  "$momo_repo/Apps/iPhoneApp/Platform/SystemActions/PhoneHealthContext.swift" \
  "$momo_repo/Apps/iPhoneApp/Features/Settings/SystemConnectionView.swift" \
  "$momo_repo/Apps/iPhoneApp/Features/Settings/PhoneConnectionOptions.swift" \
  "$momo_repo/Apps/iPhoneApp/Features/Settings/WebSettingsView.swift" \
  "$momo_repo/Apps/iPhoneApp/Features/Settings/PhoneGmailSetupView.swift" \
  "$momo_repo/Apps/iPhoneApp/Features/Settings/PhoneGmailSetupGuideView.swift"
