import AppKit
import Foundation

@main
struct VolumeMountTroubleshooterApplication {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--self-test"] {
            guard runSelfTests() else {
                FileHandle.standardError.write(Data("Self-test failed\n".utf8))
                exit(1)
            }
            print("Self-test passed")
            exit(0)
        }

        if CommandLine.arguments.dropFirst() == ["--scan-test"] {
            let runner = CommandRunner()
            let scanner = DiskScanner(runner: runner)
            do {
                let snapshot = try scanner.scan { command in
                    print("$ \(command)")
                }
                let ioreg = try runner.run(
                    executable: "/usr/sbin/ioreg",
                    arguments: ["-p", "IOUSB", "-l", "-w0"],
                    timeoutSeconds: 15
                ) { _ in }
                for disk in snapshot.disks {
                    print("DISK \(disk.identifier) | \(disk.name) | \(disk.busProtocol) | SMART \(disk.smartStatus)")
                    let speed = usbLinkSpeedBitsPerSecond(from: ioreg.output, productName: disk.name)
                    print("USB_SPEED \(speed.map(formattedLinkSpeed) ?? "unavailable")")
                    for volume in disk.volumes {
                        print("VOLUME \(volume.identifier) | \(volume.name) | \(volume.filesystem) | mounted=\(volume.mountPoint != nil) | encrypted=\(volume.isEncrypted) | locked=\(volume.isLocked)")
                    }
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Scan test failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        let application = NSApplication.shared
        guard
            let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
            let applicationIcon = NSImage(contentsOfFile: iconPath)
        else {
            fatalError("AppIcon.icns is missing or unreadable in the application bundle")
        }
        application.applicationIconImage = applicationIcon
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
