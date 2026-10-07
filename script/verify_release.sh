#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    print -u2 "usage: $0 RELEASE_ZIP SHA256SUMS_FILE"
    exit 2
fi

archive_path="${1:A}"
checksum_path="${2:A}"

if [[ ! -f "$archive_path" ]]; then
    print -u2 "release archive does not exist: $archive_path"
    exit 1
fi
if [[ ! -f "$checksum_path" ]]; then
    print -u2 "checksum file does not exist: $checksum_path"
    exit 1
fi

archive_dir="${archive_path:h}"
archive_name="${archive_path:t}"
checksum_name="${checksum_path:t}"
verification_dir="$(/usr/bin/mktemp -d "${TMPDIR%/}/VolumeMountTroubleshooter-release.XXXXXX")"

cleanup() {
    /bin/rm -rf "$verification_dir"
}
trap cleanup EXIT

(
    cd "$archive_dir"
    /usr/bin/shasum -a 256 -c "$checksum_name"
)

/usr/bin/ditto -x -k "$archive_path" "$verification_dir"

app_path="$verification_dir/Volume Mount Troubleshooter.app"
binary_path="$app_path/Contents/MacOS/VolumeMountTroubleshooter"

if [[ ! -d "$app_path" ]]; then
    print -u2 "release archive does not contain the expected application bundle: $archive_name"
    exit 1
fi

/usr/bin/xcrun lipo "$binary_path" -verify_arch arm64
/usr/bin/xcrun lipo "$binary_path" -verify_arch x86_64
if ! native_execution="$(/usr/bin/plutil -extract LSRequiresNativeExecution raw -expect bool "$app_path/Contents/Info.plist")"; then
    print -u2 "Release app is missing a valid boolean LSRequiresNativeExecution in Contents/Info.plist. Rebuild with the native launch policy before packaging."
    exit 1
fi
if [[ "$native_execution" != "true" ]]; then
    print -u2 "Release app permits Rosetta translation: LSRequiresNativeExecution must be true. Rebuild with the native launch policy before packaging."
    exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
"$binary_path" --self-test

print "Verified universal release: $archive_path"
