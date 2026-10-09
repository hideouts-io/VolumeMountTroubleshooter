# Repository workflow

- Preserve ./script/build_release.sh and ./script/verify_release.sh checks for checksums, signatures, architectures, native execution policy, and self-tests.
- Release approval requires both Build and verify universal app and Verify packaged app on Intel to succeed for the intended revision.
- Confirm a release tag equals v plus CFBundleShortVersionString in Info.plist.
- A v* tag push publishes through .github/workflows/macos-ci.yml after verification; obtain authorization covering publication before pushing it, and retain owner approval on github-release.
- Swift CodeQL uses the explicit ./build.sh path because this project is compiled directly with swiftc. Verify successful Swift analysis separately from Actions scanning.
- Source extraction and analysis use read-only tokens with upload: never and upload-database: false. Separate upload-only jobs publish SARIF; Code scanning uploads must succeed for every configured language.
