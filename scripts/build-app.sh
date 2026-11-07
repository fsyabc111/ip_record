#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --build-system native -c release --arch arm64
bin_dir="$(swift build --build-system native -c release --arch arm64 --show-bin-path)"
app="$PWD/dist/IP Record.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ip2region"
cp "$bin_dir/IPRecord" "$app/Contents/MacOS/IPRecord"
cp packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp packaging/Info.plist "$app/Contents/Info.plist"
cp data/ip2region/*.xdb data/ip2region/manifest.json "$app/Contents/Resources/ip2region/"
cp vendor/ip2region/LICENSE.md "$app/Contents/Resources/ip2region/LICENSE.md"
codesign --force --sign "${IPRECORD_SIGN_IDENTITY:--}" --identifier local.fsy.iprecord "$app"
codesign --verify --strict --verbose=2 "$app"
echo "Built: $app"
