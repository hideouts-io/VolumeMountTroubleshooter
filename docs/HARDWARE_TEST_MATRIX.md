# Hardware Test Matrix

This matrix tracks deliberate testing of Volume Mount Troubleshooter against real storage hardware. Automated parser tests and a successful application launch do not establish that a hardware row passed.

## Status vocabulary

| Status | Meaning |
|---|---|
| `NOT RUN` | No result has been recorded for the current build and hardware path. |
| `PASS` | Every expected result was observed and the required evidence was saved. |
| `FAIL` | The observed behavior did not meet one or more expected results. |
| `BLOCKED` | The test could not complete; record the exact environmental or hardware limitation. |
| `HISTORICAL` | The behavior was observed on an earlier build, but has not been repeated on the current build. |

Do not turn `NOT RUN`, `BLOCKED`, missing SMART data, or an untested filesystem into a passing result.

## Safety boundary

- Use disposable test media with a verified backup. Do not use irreplaceable evidence media.
- Record the app build or Git commit, macOS version, Mac model, filesystem, enclosure or bridge, cable, port, and hub path.
- Redact device serial numbers, volume UUIDs, disk UUIDs, usernames, and private filenames before publishing evidence.
- Never enter a password or recovery key into the app or its console. Unlock encrypted media through Finder, Disk Utility, or the vendor utility.
- Do not use force-unmount, repair, erase, repartition, or SMART self-test commands as part of this matrix.
- Treat `/dev/diskN` identifiers as transient. Reconfirm the selected volume immediately before every action.
- For read-only tests, verify the post-action state with fresh `diskutil info -plist` output. A successful command exit alone is not a pass.

## Required configurations

Each row must be repeated for every materially different bridge, enclosure, or filesystem driver being supported. A direct USB-C result does not certify the same drive behind a hub, and a native macOS NTFS result does not certify a third-party NTFS driver.

| ID | Configuration and operation | Expected result | Required evidence | Status |
|---|---|---|---|---|
| HT-01 | Unencrypted APFS volume: inspect, mount normally, unmount, and safe eject | One user-facing APFS volume appears; helper APFS roles stay excluded; each action targets only the selected volume or its containing disk as labeled; selector state refreshes after every action | Redacted console report, before/after `diskutil info -plist`, app build, device and connection record | `NOT RUN` |
| HT-02 | Encrypted APFS volume while locked, then after an external unlock | Locked state is detected without collecting credentials; mount actions remain unavailable while locked; after the user unlocks outside the app, automatic discovery replaces stale state and exposes the data volume | Redacted locked/unlocked reports, transition timing, before/after volume state, confirmation that no credential text entered the app | `NOT RUN` |
| HT-03 | ExFAT volume: inspect, read-only mount, normal mount, unmount, and safe eject | Filesystem is identified as ExFAT; read-only and normal mount states are freshly verified; operations remain limited to the selected device | Redacted console reports and before/after `diskutil info -plist` for both mount modes | `HISTORICAL` |
| HT-04 | NTFS volume using native macOS support, then separately with any explicitly supported third-party driver | The observed mount capability is reported exactly; native read-only behavior is not mislabeled writable; driver-specific failures remain visible and are not generalized to all NTFS devices | Driver name/version, redacted reports, before/after mount flags, exact command output | `NOT RUN` |
| HT-05 | Hardware-encrypted drive that initially exposes a virtual unlocker CD | Unlocker is excluded from the data-volume selector; **Show Unlocker in Finder** reveals only its mounted location; the app never launches the utility or handles credentials; progression reaches the full data disk after external unlock | Redacted progression log, unlocker and data-disk topology, transition duration, final selected volume | `HISTORICAL` |
| HT-06 | Two or more external physical disks, including one disk that produces an inventory error | Every usable disk remains selectable; the faulty disk's identifier and exact error are reported; actions affect only the selected volume or selected whole disk | Redacted inventory report, device count, injected or naturally observed fault details, before/after disk list | `NOT RUN` |
| HT-07 | Disconnect the selected drive during an inventory scan, inspection, and an idle selected state | Disk Arbitration disappearance is handled immediately; stale selector entries are removed; Mount, Unmount, and Eject controls disable; disconnect during a command fails clearly without targeting a replacement disk identifier | Timestamped redacted console log for each timing point and a screenshot of cleared controls | `NOT RUN` |
| HT-08 | Busy mounted volume: hold a file or working directory open, then request unmount, read-only remount, and safe eject | macOS `Resource busy` or equivalent output is preserved; the app provides actionable guidance; no force operation is attempted; the disk remains represented accurately | Process used to hold the volume busy, exact redacted error, final `diskutil info -plist` state | `NOT RUN` |
| HT-09 | One drive directly attached and through powered and unpowered USB hubs | Attachment remains discoverable when macOS publishes it; System Profiler and IOKit evidence is shown without treating link speed as throughput; hub power or bridge limitations are reported as observed | Hub model and power mode, cable and port, System Profiler excerpt, IOKit link speed, redacted app report | `NOT RUN` |
| HT-10 | Writable mounted APFS and ExFAT volumes remounted read-only | The app shows the confirmation boundary, unmounts without force, mounts read-only, and accepts success only after fresh state reports read-only; failure leaves an exact error and current state | Confirmation screenshot, complete redacted command sequence, before/after `diskutil info -plist`, final mount point | `NOT RUN` |

The `HISTORICAL` ExFAT and virtual-unlocker entries reflect the previously observed SanDisk unlock transition. Repeat them on the current build before changing either row to `PASS`.

## Common preparation

1. Record the current revision and build the app:

   ```sh
   git rev-parse HEAD
   ./build.sh
   ```

2. Run the read-only inventory test before changing device state:

   ```sh
   "build/Volume Mount Troubleshooter.app/Contents/MacOS/VolumeMountTroubleshooter" \
     --scan-test
   ```

3. Start the GUI, enable report redaction, attach only the devices required by the row, and select the intended volume explicitly.
4. Save a redacted report before and after the tested action. Record unexpected behavior verbatim.
5. Safe-eject test media when the row permits it. If ejection fails, preserve the error and stop rather than forcing removal.

## Result record

Copy this block once per matrix execution. Keep one result per hardware path; do not overwrite a failure with a later pass.

```text
Test ID:
Status: NOT RUN | PASS | FAIL | BLOCKED
Date and tester:
Git commit or build identifier:
macOS version and build:
Mac model:
Drive make and model:
Capacity:
Filesystem and encryption state:
Bridge or enclosure:
Cable, port, and hub path:
Filesystem driver and version, if applicable:
Initial diskutil identity:
Expected result:
Observed result:
Exact error and exit status:
Disk Arbitration progression:
SMART availability and vendor caveat:
Evidence file paths:
Privacy review completed by:
Notes:
```

## Passing the matrix

The project may describe an individual configuration as hardware-tested only when its row is `PASS` and the result record identifies the exact build, macOS version, drive, filesystem, bridge, and connection path. The application as a whole should not be called fully hardware-validated while required rows remain `NOT RUN`, `FAIL`, or `BLOCKED`.
