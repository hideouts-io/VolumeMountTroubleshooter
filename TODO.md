# Selected storage transport

The feature answers: **How is this selected storage device physically connected to my Mac, and could that connection explain the observed storage behavior?**

1. [x] Verify the canonical checkout, applicable instructions and existing changes.
   - Primary repository: `hideouts-io/VolumeMountTroubleshooter`.
   - Preserve the preexisting README reorganization outside the feature commit. A local feature branch and commit are authorized.
2. [x] Inspect the exact PlugSense repository, relevant source and license.
   - Reference: [yasir24s/PlugSense at eb3b4e7](https://github.com/yasir24s/PlugSense/tree/eb3b4e73927c02dfa65abb66f6a6038fb9b90303).
   - GPL-3.0 reference; independently implement native API collection without copying source, tests, assets or adding a dependency.
3. [x] Implement typed transport observations and a read-only IOKit scanner.
   - Exact current whole-disk IOMedia BSD match; bounded, unique parent ancestry.
   - Controller, port, hub, USB storage endpoint, interface and media evidence.
   - Negotiated link rate and descriptor revision remain separate; missing data is explicit.
4. [x] Integrate physical-store correlation with disk/volume snapshots.
   - Validate partitions and synthesized APFS volumes against physical stores.
   - Reject ambiguous single-path associations and stale or replaced disk identities.
5. [x] Show the selected connection path and include evidence in reports.
   - Existing UI and reports only; remove broad USB inventory output and product-name speed matching.
   - Explicit transport coverage, conservative explanations and report redaction.
6. [x] Validate the implementation and review the complete diff.
   - Passed: `./script/build_and_run.sh --verify` — universal arm64/x86_64 build, native self-tests, strict ad-hoc signature verification and app launch.
   - Passed: Intel self-tests under the installed Rosetta runtime; Swift type checking, shell syntax, Info.plist validation and `git diff --check`.
   - Passed: `--scan-test` on the attached SanDisk Extreme SSD. Current `disk10s1` → `disk10` association, AppleT8122USBXHCI controller, AppleUSB30XHCIARMPort, SanDisk USB VID/PID, UAS interface and a 10.0 Gb/s negotiated endpoint link were observed. No hub ancestor was observed; this does not exclude an unenumerated adapter or dock.
   - Passed: source review after fixing media continuity independently of topology availability and keeping label/tooltip evidence consistent.
   - Passed: native GUI discovery, selected connection display and Inspect on the attached SSD. The final rebuilt app completed inspection using the same exact media/path correlation and 10.0 Gb/s endpoint evidence.
   - Passed: native Save Report interaction using stable accessibility IDs. The saved report retained topology, correlation, VID/PID, negotiated rate, coverage and bounded explanations; registry IDs, location IDs and UUIDs were redacted. No broad USB inventory collectors appeared in the report.
   - Runtime caveat: earlier GUI scans timed out after 15 seconds on `diskutil info -plist /dev/disk9` and `/dev/disk10` in both the feature build and an unchanged committed-source comparison app. A sampled comparison child was blocked in `DiskManagement`'s `wholeDiskSupportsLowLevelFormat` device-open query. Current discovery and Inspect succeed; the earlier cause remains unresolved and is not claimed fixed. The agent changed no permissions or device settings.
   - Generated local evidence: `build/transport-scan-test.txt`, `build/transport-gui-report-20261006.txt` and `build/transport-baseline/` (ignored by Git). The comparison app was stopped after diagnosis.
   - Not run on physical hardware: intermediate hubs/docks, multi-store APFS, Thunderbolt/USB4 enrichment, disconnect/replacement during collection, older macOS or a native Intel Mac. Synthetic correlation/cancellation checks do not establish those runtime scenarios.
7. [x] Verify native launch compatibility after the macOS 28 Rosetta warning.
   - `LSRequiresNativeExecution=true` requires native execution through LaunchServices while retaining both universal binary slices. Release verification requires that boolean policy before running packaged self-tests.
   - Passed: universal build, native self-tests, strict signature verification, ZIP/checksum/extracted-package verification, shell syntax, plist validation and diff checks.
   - Passed: packaging rejection of the previous bundle with the policy missing and a task-owned package with the policy disabled.
   - Passed: normal GUI launch sampled as ARM64 on macOS 27; selected SSD discovery and Inspect completed without forced Intel execution.
   - The previous explicit Intel self-test ran under Rosetta and can trigger this warning. It is not evidence that the normal ARM64 app requires an Intel-only component.
   - No Intel-only bundled executable or required system helper was found. The optional SMART collector is not installed. Native Intel hardware and macOS 28 runtime behavior remain unverified locally.
   - Local package evidence: `build/native-launch-validation.b4n6Af/`; native process evidence: `build/macos28-native-app-sample.txt` (ignored by Git).

8. [x] Make connection evidence readable without internal identifiers.
   - [x] Replace registry/location IDs and driver-stack output with the observed physical path, negotiated speed and storage protocol.
   - [x] Keep disk identity validation internal; retain concise, explicit coverage limits and evidence-bounded explanations.
   - [x] Build, run native self-tests and type checks, and verify Inspect plus Save Report on attached storage.
   - Passed: universal build, native self-tests, Swift type checking, strict signature verification, plist/shell checks and diff review.
   - Passed: selected SSD transport collection, native display, Inspect and Save Report. The saved connection section contains 13 nonempty lines instead of 48, preserving the path, 10.0 Gb/s negotiated speed, UAS protocol, verified disk match and coverage limits without internal IDs, driver classes or redaction placeholders.
   - Runtime caveat: the existing 15-second diskutil timeouts recurred during initial discovery. The command-line scan retained the SSD with an isolated unlocker-disk failure; the subsequent native GUI discovery and selected SSD inspection/export completed. The timeout cause remains unresolved. Hub/dock and non-USB report paths remain unverified on physical hardware.
   - Local evidence: `build/readable-transport-build.log`, `build/readable-transport-scan.txt` and `build/readable-transport-gui-report-20261006-2230.txt` (ignored by Git).

9. [x] Verify report readability, live diagnostics and existing feature behavior.
   - [x] Establish the canonical checkout, instructions and review state; preserve the existing README reorganization.
   - [x] Build and run natively; exercise discovery, Inspect, summary, Copy/Save and cancellation, and review the tooltip's shared report binding.
   - [x] Review current selected-storage correlation, speed/protocol attribution, coverage, SMART, selection/control states, cancellation and failure isolation.
   - [x] Trace and fix report clutter, empty log headers, stale observations, unsafe identity continuation, unknown-state assertions, split UTF-8 decoding and the blocked Save dialog.
   - [x] Repeat relevant runtime flows and inspect matching copied/saved reports, privacy and native command failure evidence.
   - [x] Run build/self-tests/type/syntax/signature checks and review the complete diff, preserving the preexisting README reorganization.
   - Passed live: SanDisk Extreme 55AE, 2 TB ExFAT volume /dev/disk4s1 backed by current /dev/disk4; exact media/ancestry match, negotiated 10.0 Gb/s USB link and UAS. Discovery retained the separate vendor unlocker without including it in the selected inspection report.
   - Passed live: Refresh disables selection/actions and restores them; Stop cancels a read-only inspection and Inspect recovers; the nonblocking native save sheet writes a report matching Copy Report byte for byte, and cancelling Save writes nothing. The report has 39 nonempty lines without raw UUID/registry/location fields, unrelated disks, redaction placeholders or broken Unicode.
   - Passed native checks: universal ARM64/Intel compilation, native ARM64 self-tests, strict signature/architecture checks, Swift type checking, plist/shell syntax and diff checks. A task-owned subprocess split a Unicode character across pipe reads; streamed and captured output agreed. Invalid UTF-8, nonzero command output, pre-launch cancellation and deadlines were exercised.
   - Synthetic/static coverage: unknown encryption/writability/SMART observations, packed ATA fields and normalized metric validation, APFS backing-store disappearance/ambiguity, per-disk failure isolation and identity checks before storage mutations. These checks do not establish live hardware behavior for those paths.
   - Unverified: encrypted/APFS/multi-store or nested user-volume hardware, physical hubs/docks/Thunderbolt/USB4, disconnect/reuse races, real detailed SMART, native Intel GUI/storage hardware and older/future macOS, tooltip hover and a forced report-write failure. Mount/unmount/remount/eject were not performed on the attached data disk.
   - No diskutil timeout occurred in this pass's live scans/inspections; the previously observed intermittent timeout cause remains unresolved.
   - Local evidence: build/report-audit-final-build.log, build/report-audit-typecheck.log, build/report-audit-live-scan.txt, build/report-audit-final-process.sample, build/report-audit-copied-final-20261007.txt and build/volume-mount-report-20261007-190243.txt (ignored by Git).
   - The verified selected-storage fixes are authorized for a focused commit, feature-branch push and pull request. Preserve the preexisting README reorganization outside that commit; state-changing storage operations require an explicitly authorized disposable device.

Out of scope: phone charging/battery/diagnostics, accessory monitoring, general USB inventory, display diagnostics, power dashboards, inferred cable faults, state-changing hardware tests and unrelated publication.
