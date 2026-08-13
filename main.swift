import AppKit
import Foundation

struct CommandResult {
    let exitStatus: Int32
    let output: String
}

enum TroubleshooterError: LocalizedError {
    case commandLaunchFailed(executable: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .commandLaunchFailed(executable, reason):
            return "Could not launch \(executable): \(reason)"
        }
    }
}

func shellQuoted(_ value: String) -> String {
    let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
    if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func renderedCommand(executable: String, arguments: [String]) -> String {
    ([executable] + arguments).map(shellQuoted).joined(separator: " ")
}

func externalDiskIdentifiers(from output: String) -> [String] {
    let pattern = #"(?m)^/dev/(disk[0-9]+) \(external, physical\):$"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return []
    }

    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    return expression.matches(in: output, range: range).compactMap { match in
        guard let identifierRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[identifierRange])
    }
}

func relatedDiskIdentifiers(from output: String, physicalIdentifiers: [String]) -> [String] {
    let pattern = #"Apple_APFS Container (disk[0-9]+)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return physicalIdentifiers
    }

    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    let containerIdentifiers: [String] = expression.matches(in: output, range: range).compactMap { match -> String? in
        guard let identifierRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[identifierRange])
    }
    return Array(Set(physicalIdentifiers + containerIdentifiers)).sorted()
}

func mountedExternalVolumeLines(from output: String, diskIdentifiers: [String]) -> [String] {
    output.split(separator: "\n").compactMap { rawLine in
        let line = String(rawLine)
        let belongsToExternalDisk = diskIdentifiers.contains { identifier in
            line.hasPrefix("/dev/\(identifier)")
        }
        return belongsToExternalDisk && line.contains(" on /Volumes/") ? line : nil
    }
}

func systemProfilerReportsAttachedDevice(_ output: String) -> Bool {
    let hasUSBDeviceTree = output.range(of: #"(?m)^USB:$"#, options: .regularExpression) != nil
    let hasConnectedThunderboltDevice = output.contains("Status: Device connected")
    return hasUSBDeviceTree || hasConnectedThunderboltDevice
}

final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?
    private var cancellationRequested = false

    func reset() {
        lock.lock()
        cancellationRequested = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = currentProcess
        lock.unlock()
        process?.terminate()
    }

    func isCancelled() -> Bool {
        lock.lock()
        let result = cancellationRequested
        lock.unlock()
        return result
    }

    func run(
        executable: String,
        arguments: [String],
        onOutput: @escaping (String) -> Void
    ) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        lock.lock()
        currentProcess = process
        lock.unlock()

        defer {
            lock.lock()
            currentProcess = nil
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw TroubleshooterError.commandLaunchFailed(
                executable: executable,
                reason: error.localizedDescription
            )
        }

        var completeOutput = ""
        let readHandle = outputPipe.fileHandleForReading
        while true {
            let data = readHandle.availableData
            if data.isEmpty {
                break
            }
            let chunk = String(decoding: data, as: UTF8.self)
            completeOutput.append(chunk)
            onOutput(chunk)
        }

        process.waitUntilExit()
        return CommandResult(exitStatus: process.terminationStatus, output: completeOutput)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runner = CommandRunner()
    private var window: NSWindow?
    private var textView: NSTextView?
    private var statusLabel: NSTextField?
    private var startButton: NSButton?
    private var stopButton: NSButton?
    private var copyButton: NSButton?
    private var saveButton: NSButton?
    private var revealButton: NSButton?
    private var completeLog = ""
    private var isRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)

        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "Quit Volume Mount Troubleshooter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationMenuItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
    }

    private func configureWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Volume Mount Troubleshooter"
        window.center()
        window.minSize = NSSize(width: 720, height: 480)

        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootView

        let titleLabel = NSTextField(labelWithString: "External Volume Mount Troubleshooter")
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "Detects attached USB/Thunderbolt storage, shows every command, and asks macOS to mount each external physical disk. It never erases, formats, or repairs a disk."
        )
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: "Ready — attach a volume and press Start")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        self.statusLabel = statusLabel

        let startButton = NSButton(title: "Start", target: self, action: #selector(startTroubleshooting))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.translatesAutoresizingMaskIntoConstraints = false
        self.startButton = startButton

        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stopTroubleshooting))
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        self.stopButton = stopButton

        let copyButton = NSButton(title: "Copy Log", target: self, action: #selector(copyLog))
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        self.copyButton = copyButton

        let saveButton = NSButton(title: "Save Report…", target: self, action: #selector(saveReport))
        saveButton.bezelStyle = .rounded
        saveButton.isEnabled = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        self.saveButton = saveButton

        let revealButton = NSButton(title: "Show Volumes", target: self, action: #selector(revealVolumes))
        revealButton.bezelStyle = .rounded
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        self.revealButton = revealButton

        let buttonStack = NSStackView(views: [startButton, stopButton, copyButton, saveButton, revealButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(calibratedRed: 0.78, green: 0.94, blue: 0.80, alpha: 1)
        textView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        self.textView = textView

        [titleLabel, subtitleLabel, statusLabel, buttonStack, scrollView].forEach(rootView.addSubview)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

            buttonStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            buttonStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20)
        ])

        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    @objc private func startTroubleshooting() {
        guard !isRunning else {
            return
        }

        isRunning = true
        completeLog = ""
        textView?.string = ""
        runner.reset()
        setControlsForRunningState(true)
        setStatus("Running hardware and mount diagnostics…", color: .systemBlue)

        let runner = self.runner
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performTroubleshooting(using: runner)
        }
    }

    @objc private func stopTroubleshooting() {
        runner.cancel()
        appendLog("\nStop requested. Terminating the active command…\n")
        setStatus("Stopping…", color: .systemOrange)
    }

    @objc private func copyLog() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(completeLog, forType: .string)
        setStatus("Log copied to the clipboard", color: .systemGreen)
    }

    @objc private func saveReport() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "volume-mount-report-\(formatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        do {
            try completeLog.write(to: destination, atomically: true, encoding: .utf8)
            setStatus("Report saved to \(destination.path)", color: .systemGreen)
        } catch {
            setStatus("Report save failed: \(error.localizedDescription)", color: .systemRed)
        }
    }

    @objc private func revealVolumes() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Volumes", isDirectory: true))
    }

    nonisolated private func performTroubleshooting(using runner: CommandRunner) {
        postLog("Volume Mount Troubleshooter\n")
        postLog("Started: \(ISO8601DateFormatter().string(from: Date()))\n")
        postLog("Safety: diagnostics and mount requests only; no repair, erase, or format commands.\n\n")

        do {
            let profilerResult = try runLogged(
                executable: "/usr/sbin/system_profiler",
                arguments: ["SPUSBDataType", "SPThunderboltDataType", "-detailLevel", "mini"],
                using: runner
            )
            if profilerResult.exitStatus != 0 {
                postLog("WARNING: Hardware profiling failed; continuing to the authoritative disk inventory.\n\n")
            } else if systemProfilerReportsAttachedDevice(profilerResult.output) {
                postLog("SYSTEM PROFILER CHECK: Attached USB or Thunderbolt hardware was reported.\n")
                postLog("The diskutil check below determines whether macOS also created a disk device.\n\n")
            } else {
                postLog("SYSTEM PROFILER CHECK: These data types did not describe an attached device.\n")
                postLog("This is not conclusive: diskutil may still report a USB storage disk, as checked next.\n\n")
            }

            guard !runner.isCancelled() else {
                finishCancelled()
                return
            }

            let inventoryResult = try runLogged(
                executable: "/usr/sbin/diskutil",
                arguments: ["list", "external", "physical"],
                using: runner
            )
            guard inventoryResult.exitStatus == 0 else {
                finishFailure("diskutil could not inventory external physical disks (exit \(inventoryResult.exitStatus)).")
                return
            }

            let diskIdentifiers = externalDiskIdentifiers(from: inventoryResult.output)
            guard !diskIdentifiers.isEmpty else {
                postLog("RESULT: No external physical disk was reported by Disk Arbitration.\n")
                postLog("Check the cable, adapter, hub power, and whether the device appears in the hardware profile above.\n")
                finishFailure("No external physical disk detected")
                return
            }

            postLog("Detected external physical disks: \(diskIdentifiers.joined(separator: ", "))\n\n")
            let verificationIdentifiers = relatedDiskIdentifiers(
                from: inventoryResult.output,
                physicalIdentifiers: diskIdentifiers
            )
            var failedMounts: [String] = []

            for identifier in diskIdentifiers {
                guard !runner.isCancelled() else {
                    finishCancelled()
                    return
                }

                let devicePath = "/dev/\(identifier)"
                let infoResult = try runLogged(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["info", devicePath],
                    using: runner
                )
                if infoResult.exitStatus != 0 {
                    postLog("WARNING: Could not read complete device information for \(devicePath).\n\n")
                }

                let mountResult = try runLogged(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["mountDisk", devicePath],
                    using: runner
                )
                if mountResult.exitStatus != 0 {
                    failedMounts.append(devicePath)
                    postLog("MOUNT FAILURE: \(devicePath) exited with status \(mountResult.exitStatus).\n")
                    postLog("The command output above is the exact macOS failure reason. No repair was attempted.\n\n")
                }
            }

            let mountResult = try runLogged(
                executable: "/sbin/mount",
                arguments: [],
                using: runner
            )
            let mountedLines = mountedExternalVolumeLines(
                from: mountResult.output,
                diskIdentifiers: verificationIdentifiers
            )

            postLog("External volume verification:\n")
            if mountedLines.isEmpty {
                postLog("No mount points under /Volumes were found for the detected external disks.\n")
            } else {
                mountedLines.forEach { postLog("  \($0)\n") }
            }

            if failedMounts.isEmpty && !mountedLines.isEmpty {
                finishSuccess("Mounted \(mountedLines.count) external volume(s)")
            } else if failedMounts.isEmpty {
                finishFailure("Mount command completed, but no external mount point was verified")
            } else {
                finishFailure("Mount failed for \(failedMounts.joined(separator: ", "))")
            }
        } catch let error as TroubleshooterError {
            postLog("\nFATAL: \(error.localizedDescription)\n")
            finishFailure(error.localizedDescription)
        } catch {
            postLog("\nFATAL: Unexpected execution error: \(error.localizedDescription)\n")
            finishFailure("Unexpected execution error: \(error.localizedDescription)")
        }
    }

    nonisolated private func runLogged(
        executable: String,
        arguments: [String],
        using runner: CommandRunner
    ) throws -> CommandResult {
        let command = renderedCommand(executable: executable, arguments: arguments)
        postLog("$ \(command)\n")
        let result = try runner.run(executable: executable, arguments: arguments) { [weak self] chunk in
            self?.postLog(chunk)
        }
        if !result.output.hasSuffix("\n") {
            postLog("\n")
        }
        postLog("[exit status: \(result.exitStatus)]\n\n")
        return result
    }

    nonisolated private func postLog(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog(text)
        }
    }

    nonisolated private func finishSuccess(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog("\nRESULT: SUCCESS — \(message)\n")
            self?.finish(message, color: .systemGreen)
        }
    }

    nonisolated private func finishFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog("\nRESULT: FAILED — \(message)\n")
            self?.finish(message, color: .systemRed)
        }
    }

    nonisolated private func finishCancelled() {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog("\nRESULT: CANCELLED by user\n")
            self?.finish("Cancelled", color: .systemOrange)
        }
    }

    private func appendLog(_ text: String) {
        completeLog.append(text)
        guard let textView else {
            return
        }
        textView.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.78, green: 0.94, blue: 0.80, alpha: 1)
        ]))
        textView.scrollToEndOfDocument(nil)
    }

    private func finish(_ message: String, color: NSColor) {
        isRunning = false
        setControlsForRunningState(false)
        setStatus(message, color: color)
    }

    private func setControlsForRunningState(_ running: Bool) {
        startButton?.isEnabled = !running
        stopButton?.isEnabled = running
        copyButton?.isEnabled = !running && !completeLog.isEmpty
        saveButton?.isEnabled = !running && !completeLog.isEmpty
        revealButton?.isEnabled = !running
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
    }
}

@main
struct VolumeMountTroubleshooterApplication {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--self-test"] {
            let inventory = """
            /dev/disk4 (external, physical):
               0: GUID_partition_scheme *2.0 TB disk4
               1: Apple_APFS Container disk5 1.0 TB disk4s2
            """
            let mounts = """
            /dev/disk5s1 on /Volumes/External Data (apfs, local)
            /dev/disk3s1s1 on / (apfs, local)
            """
            let physical = externalDiskIdentifiers(from: inventory)
            let related = relatedDiskIdentifiers(from: inventory, physicalIdentifiers: physical)
            let verified = mountedExternalVolumeLines(from: mounts, diskIdentifiers: related)
            guard physical == ["disk4"], related == ["disk4", "disk5"], verified.count == 1 else {
                FileHandle.standardError.write(Data("Self-test failed\n".utf8))
                exit(1)
            }
            print("Self-test passed")
            exit(0)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
