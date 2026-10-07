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

Out of scope: phone charging/battery/diagnostics, accessory monitoring, general USB inventory, display diagnostics, power dashboards, inferred cable faults, state-changing hardware tests and remote publication.
