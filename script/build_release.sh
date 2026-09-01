#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
app_path="$project_dir/build/Volume Mount Troubleshooter.app"
release_dir="$project_dir/dist"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$project_dir/Info.plist")"
archive_name="VolumeMountTroubleshooter-v$version-macOS-universal.zip"
checksum_name="VolumeMountTroubleshooter-v$version-SHA256SUMS.txt"
archive_path="$release_dir/$archive_name"
checksum_path="$release_dir/$checksum_name"

if [[ -z "$version" ]]; then
    print -u2 "CFBundleShortVersionString is empty in $project_dir/Info.plist"
    exit 1
fi

"$project_dir/build.sh"
/bin/mkdir -p "$release_dir"
/bin/rm -f "$archive_path" "$checksum_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

(
    cd "$release_dir"
    /usr/bin/shasum -a 256 "$archive_name" > "$checksum_name"
)

"$project_dir/script/verify_release.sh" "$archive_path" "$checksum_path"

print "Release archive: $archive_path"
print "Checksums: $checksum_path"
