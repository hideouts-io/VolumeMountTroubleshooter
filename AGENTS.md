# Repository workflow

- Preserve ./script/build_release.sh and ./script/verify_release.sh checks for checksums, signatures, architectures, native execution policy, and self-tests.
- Release approval requires both Build and verify universal app and Verify packaged app on Intel to succeed for the intended revision.
- Confirm a release tag equals v plus CFBundleShortVersionString in Info.plist.
- A v* tag push publishes through .github/workflows/macos-ci.yml after verification; obtain authorization covering publication before pushing it, and retain owner approval on github-release.
- Swift CodeQL uses the explicit ./build.sh path because this project is compiled directly with swiftc. Verify successful Swift analysis separately from Actions scanning.
- Source extraction and analysis use read-only tokens with upload: never and upload-database: false. Separate upload-only jobs publish SARIF; Code scanning uploads must succeed for every configured language.

# Project working defaults

These instructions apply only to this project and its canonical repository.

## Session setup and continuity

- Read `WORKSPACE.md`, the applicable `AGENTS.md` and `AGENTS.override.md` files, the actual TODO list, project documentation, and the latest project checkpoint before making changes. Always verify the canonical checkout, Git root, current branch, HEAD, remote, upstream, attached worktrees, open pull requests, and staged, unstaged, and untracked files. Preserve all unrelated work.
- Do not start adapters, dependencies, installers, packaging, or CI work while an actionable TODO remains.
- Maintain durable project continuity during active work. At the beginning of a work session, load the latest project memory and checkpoint. At least once every hour while actively working, and again before ending or pausing, save a concise checkpoint containing the current objective and scope; canonical checkout and worktree; branch, HEAD, remote branch, pull request URL and number; relevant staged, unstaged, and untracked state; intentionally changed files; completed TODO items; implementation decisions and reasons; test, build, CI, and native-check status; application bundle path and native-window evidence when applicable; investigated failures and approaches not to repeat; remaining TODOs in established order; blockers; and the next safe action.
- Use the existing project checkpoint or continuity location instead of creating duplicate planning documents. Do not store credentials, secrets, signing material, device identifiers, raw backups, private logs, downloaded threat intelligence, personal information, or large command output in memory. Record safe summaries and paths to private local evidence instead.
- Hourly checkpointing is a minimum interval, not a reason to interrupt a running build, test, or CI job. Save the checkpoint at the next safe boundary. Do not create empty or repetitive hourly entries when no project state changed; update the existing checkpoint with the current timestamp and status.

## Standing Git and GitHub delivery authorization

For this project only, normal Git and GitHub delivery steps for work implemented and verified in the current task are authorized. This includes staging only reviewed task files or hunks, focused conventional commits, creating or using a `codex/` feature branch when appropriate, pushing ordinary non-force changes to the verified GitHub repository, creating or updating a pull request, marking a draft ready after implementation and required checks complete, and pushing follow-up fixes needed for required CI checks.

- Use a pull request by default for source, application behavior, packaging, workflow, dependency, security-sensitive, or substantial multi-file changes. A direct push is acceptable only on the correct non-protected task branch, following repository practice, without bypassing required review or branch protection.
- Before every commit or push, confirm the canonical repository, branch, remote URL, upstream, HEAD, and outgoing diff; preserve unrelated index and worktree state; inspect the complete staged diff; check for credentials, private evidence, device identifiers, personal data, local absolute paths, backups, logs, downloaded indicators, build caches, and private test artifacts; run applicable tests, linting, documentation, packaging, and native UI checks; review the final diff; fetch and inspect the verified remote before integrating; push only the intended branch; verify the remote revision; and inspect resulting GitHub checks.
- Never use `git add .`, `git add -A`, or `git commit -a` in the dirty canonical checkout. Do not reset, clean, stash, discard, overwrite, or silently include unrelated changes. If overlapping work conflicts, preserve it and use a suitable review worktree or create a focused worktree from the correct committed base.
- This authorization does not cover merging a pull request, force-pushing or rewriting published history, deleting remote branches, creating tags or releases, publishing release artifacts, deploying an application or website, approving protected environments or publication jobs, changing branch protection, repository visibility, permissions, secrets, Actions settings, or other repository settings, installing or broadening GitHub App access, or sending unrelated external messages or review responses. Ask separately before those operations.
- A successful pull request and passing CI do not authorize a merge, release, deployment, or publication.

## Completion and evidence

- Continue autonomously through implementation, verification, commit, push, pull-request creation or update, and CI repair under this standing authorization. Report what changed and why; commit hashes and pushed branch; pull-request URL and review state; test, build, and CI outcomes; remaining macOS TODOs and concrete blockers; the exact path and visible state of the updated app when applicable; and any publication-sensitive step that still needs authorization.
- Preserve evidence boundaries. Distinguish confirmed, inferred, unresolved, and unverified results, and distinguish static, synthetic, simulator, native UI, physical-device, hosted, and release evidence. Do not treat a successful build, static analysis, synthetic fixture, or package check as proof of live runtime behavior, physical-device operation, publication, or release approval.
