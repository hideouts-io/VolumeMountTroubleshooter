#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app_dir="$build_dir/Volume Mount Troubleshooter.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
slice_dir="$build_dir/slices"
binary_path="$macos_dir/VolumeMountTroubleshooter"
arm64_binary="$slice_dir/VolumeMountTroubleshooter-arm64"
x86_64_binary="$slice_dir/VolumeMountTroubleshooter-x86_64"
source_files=(
  "$project_dir/Diagnostics.swift"
  "$project_dir/SystemConnectors.swift"
  "$project_dir/AppDelegate.swift"
  "$project_dir/main.swift"
)

/bin/rm -rf "$app_dir"
/bin/rm -rf "$slice_dir"
/bin/mkdir -p "$macos_dir" "$resources_dir" "$slice_dir"

compile_slice() {
  local architecture="$1"
  local output_path="$2"
  local module_cache_path="$build_dir/module-cache-$architecture"

  /bin/mkdir -p "$module_cache_path"

  /usr/bin/xcrun swiftc \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -module-cache-path "$module_cache_path" \
    -target "$architecture-apple-macos13.0" \
    -framework AppKit \
    -framework DiskArbitration \
    "${source_files[@]}" \
    -o "$output_path"
}

compile_slice "arm64" "$arm64_binary"
compile_slice "x86_64" "$x86_64_binary"

/usr/bin/xcrun lipo \
  -create \
  "$arm64_binary" \
  "$x86_64_binary" \
  -output "$binary_path"
/usr/bin/xcrun lipo "$binary_path" -verify_arch arm64 x86_64
/bin/rm -rf "$slice_dir"
/bin/rm -rf "$build_dir/module-cache-arm64" "$build_dir/module-cache-x86_64"

/bin/cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
/bin/cp "$project_dir/assets/AppIcon.icns" "$resources_dir/AppIcon.icns"
"$binary_path" --self-test
/usr/bin/codesign --force --sign - --timestamp=none "$app_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"

print "Architectures: $(/usr/bin/xcrun lipo -archs "$binary_path")"
print "Built: $app_dir"
