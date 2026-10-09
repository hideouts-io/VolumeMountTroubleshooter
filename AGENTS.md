# Repository instructions

## Git and GitHub

- Verify the canonical checkout, applicable overrides, branch, origin, revision, index, and dirty files before Git changes. Preserve unrelated work; isolate conflicting work in a worktree.
- Use a focused codex/ branch for a reviewable change. Keep uncommitted work available for user review unless a commit is authorized.
- Commit, push, PR creation, merge, tag, release, deployment, visibility changes, and deletion require authorization covering the operation and target. Honor an existing scoped authorization; do not infer publication from implementation approval.
- Stage explicit paths or approved hunks, review the complete staged diff, and keep private evidence and secrets out of GitHub.
- Merge only after applicable checks and conversations are satisfied for the latest candidate revision. Preserve required checks and prefer merge commits over rebase or squash when compatible with repository rules.
- Pin external Actions to upstream-verified full commit SHAs. Run PR code with read-only tokens. Give security-events write only to separate upload jobs that execute pinned Actions without repository scripts; publishing jobs require the protected github-release environment.

## Repository workflow

- Preserve ./script/build_release.sh and ./script/verify_release.sh checks for checksums, signatures, architectures, native execution policy, and self-tests.
- Release approval requires both Build and verify universal app and Verify packaged app on Intel to succeed for the intended revision.
- Confirm a release tag equals v plus CFBundleShortVersionString in Info.plist.
- A v* tag push publishes through .github/workflows/macos-ci.yml after verification; obtain authorization covering publication before pushing it, and retain owner approval on github-release.
- Swift CodeQL uses the explicit ./build.sh path because this project is compiled directly with swiftc. Verify successful Swift analysis separately from Actions scanning.
