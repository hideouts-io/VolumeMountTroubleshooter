#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app_dir="$build_dir/Volume Mount Troubleshooter.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

/bin/rm -rf "$app_dir"
/bin/mkdir -p "$macos_dir" "$resources_dir"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -target "arm64-apple-macos13.0" \
  -framework AppKit \
  -framework DiskArbitration \
  "$project_dir/Diagnostics.swift" \
  "$project_dir/SystemConnectors.swift" \
  "$project_dir/AppDelegate.swift" \
  "$project_dir/main.swift" \
  -o "$macos_dir/VolumeMountTroubleshooter"

/bin/cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
/bin/cp "$project_dir/assets/AppIcon.icns" "$resources_dir/AppIcon.icns"
"$macos_dir/VolumeMountTroubleshooter" --self-test
/usr/bin/codesign --force --sign - --timestamp=none "$app_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"

print "Built: $app_dir"
