#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/Vendor/TailscaleKit"
build="$src/Build"
mkdir -p "$build"
cd "$src"
for goarch in arm64 amd64; do
 clangarch=arm64; if [[ "$goarch" == amd64 ]]; then clangarch=x86_64; fi
 MACOSX_DEPLOYMENT_TARGET=14.0 GOARCH="$goarch" CGO_ENABLED=1 CC=clang CGO_CFLAGS="-arch $clangarch -mmacos-version-min=14.0" CGO_LDFLAGS="-arch $clangarch -mmacos-version-min=14.0" go build -buildmode=c-archive -o "$build/libtailscale-$goarch.a"
done
lipo -create "$build/libtailscale-arm64.a" "$build/libtailscale-amd64.a" -output libtailscale.a
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$src/swift/script/clangwrap-ios.sh" go build -ldflags -w -tags ios -buildmode=c-archive -o libtailscale_ios.a
for goarch in arm64 amd64; do
 wrapper=arm; if [[ "$goarch" == amd64 ]]; then wrapper=x86; fi
 CGO_ENABLED=1 GOOS=ios GOARCH="$goarch" CC="$src/swift/script/clangwrap-ios-sim-$wrapper.sh" go build -ldflags -w -tags ios -buildmode=c-archive -o "$build/libtailscale-sim-$goarch.a"
done
lipo -create "$build/libtailscale-sim-arm64.a" "$build/libtailscale-sim-amd64.a" -output libtailscale_ios_sim.a
for platform in macos ios simulator; do
 case "$platform" in
 macos) scheme='TailscaleKit (macOS)'; destination='generic/platform=macOS'; architectures='arm64 x86_64';;
 ios) scheme='TailscaleKit (iOS)'; destination='generic/platform=iOS'; architectures=arm64;;
 simulator) scheme='TailscaleKit (Simulator)'; destination='generic/platform=iOS Simulator'; architectures='arm64 x86_64';;
 esac
 xcodebuild -project swift/TailscaleKit.xcodeproj -scheme "$scheme" -configuration Release -destination "$destination" -derivedDataPath "$build/$platform" MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=18.0 ARCHS="$architectures" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build > "$build/$platform.log" 2>&1
 done
rm -rf "$build/TailscaleKit.xcframework"
xcodebuild -create-xcframework -framework "$build/macos/Build/Products/Release/TailscaleKit.framework" -framework "$build/ios/Build/Products/Release-iphoneos/TailscaleKit.framework" -framework "$build/simulator/Build/Products/Release-iphonesimulator/TailscaleKit.framework" -output "$build/TailscaleKit.xcframework"
