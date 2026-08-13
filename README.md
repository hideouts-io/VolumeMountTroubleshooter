# Volume Mount Troubleshooter

A small native macOS utility that shows exactly how macOS detects and mounts attached external storage.

Press **Start** to run a non-destructive troubleshooting sequence. The built-in console displays every command, its complete output, and its exit status. The app then reports whether external mount points were verified under `/Volumes`.

The first result is an explicit System Profiler attachment check. This shows whether the USB or Thunderbolt hardware layer reports a connected device before `diskutil` checks whether macOS created a mountable disk.

## Safety boundaries

The app runs only these read-only or reversible mount commands:

```bash
/usr/sbin/system_profiler SPUSBDataType SPThunderboltDataType -detailLevel mini
/usr/sbin/diskutil list external physical
/usr/sbin/diskutil info /dev/diskN
/usr/sbin/diskutil mountDisk /dev/diskN
/sbin/mount
```

It does not run First Aid, `fsck`, repair, erase, partition, format, unlock, or `sudo`. It does not request or store a password. Disk identifiers are discovered on every run because names such as `disk4` can change after reconnecting or restarting.

## Build and run

Requires macOS 13 or newer and the Xcode command-line tools or Xcode.

```bash
cd /Users/macbookpro/Codex/MacOS/VolumeMountTroubleshooter
chmod +x build.sh
./build.sh
open "build/Volume Mount Troubleshooter.app"
```

The build is self-contained, uses only Apple frameworks, and creates an ad-hoc signed app at:

```text
build/Volume Mount Troubleshooter.app
```

## Reading a failure

- If `system_profiler` shows the device but `diskutil list external physical` does not, macOS sees the USB or Thunderbolt hardware but has not published it as a block-storage disk. Check the cable, adapter, hub power, and enclosure.
- If System Profiler does not show the device but `diskutil` does, trust the `diskutil` storage result. Some USB storage paths are not described by the selected System Profiler data types even though Disk Arbitration has published a usable disk.
- If `diskutil` detects the disk but `mountDisk` fails, the console preserves the exact filesystem or Disk Arbitration error. The app deliberately does not attempt a repair.
- If `mountDisk` succeeds but no `/Volumes` mount point is verified, save the report for deeper filesystem and Disk Arbitration analysis.
- An encrypted volume may require unlocking through Finder or Disk Utility. The app does not collect encryption credentials.

Use **Copy Log** or **Save Report…** to preserve the full diagnostic record. **Show Volumes** opens `/Volumes` in Finder.
