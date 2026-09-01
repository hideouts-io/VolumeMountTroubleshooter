import DiskArbitration
import Darwin
import Foundation

private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""

    func append(_ text: String) {
        lock.lock()
        output.append(text)
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        let result = output
        lock.unlock()
        return result
    }
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
        timeoutSeconds: TimeInterval,
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

        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            processFinished.signal()
        }

        do {
            try process.run()
        } catch {
            throw TroubleshooterError.commandLaunchFailed(
                executable: executable,
                reason: error.localizedDescription
            )
        }

        let outputBuffer = CommandOutputBuffer()
        let readHandle = outputPipe.fileHandleForReading
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                outputGroup.leave()
            }
            while true {
                let data = readHandle.availableData
                if data.isEmpty {
                    break
                }
                let chunk = String(decoding: data, as: UTF8.self)
                outputBuffer.append(chunk)
                onOutput(chunk)
            }
        }

        let waitResult = processFinished.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            process.terminate()
            if processFinished.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                processFinished.wait()
            }
        }
        outputGroup.wait()

        if isCancelled() {
            throw TroubleshooterError.cancelled
        }
        if waitResult == .timedOut {
            throw TroubleshooterError.commandTimedOut(
                command: renderedCommand(executable: executable, arguments: arguments),
                timeoutSeconds: timeoutSeconds
            )
        }
        return CommandResult(exitStatus: process.terminationStatus, output: outputBuffer.value())
    }
}

enum ScannedExternalDisk: Sendable {
    case disk(ExternalDisk)
    case unlocker(VirtualUnlocker)
}

func externalDiskSnapshot(
    entries: [DiskListEntry],
    scanEntry: (DiskListEntry) throws -> ScannedExternalDisk
) throws -> DiskSnapshot {
    var disks: [ExternalDisk] = []
    var unlockers: [VirtualUnlocker] = []
    var scanFailures: [DiskScanFailure] = []
    for entry in entries {
        do {
            switch try scanEntry(entry) {
            case let .disk(disk):
                disks.append(disk)
            case let .unlocker(unlocker):
                unlockers.append(unlocker)
            }
        } catch TroubleshooterError.cancelled {
            throw TroubleshooterError.cancelled
        } catch let error as TroubleshooterError {
            scanFailures.append(
                DiskScanFailure(
                    diskIdentifier: entry.identifier,
                    errorDescription: error.localizedDescription
                )
            )
        }
    }
    return DiskSnapshot(
        disks: disks.sorted { $0.identifier < $1.identifier },
        unlockers: unlockers.sorted { $0.wholeDiskIdentifier < $1.wholeDiskIdentifier },
        scanFailures: scanFailures.sorted { $0.diskIdentifier < $1.diskIdentifier }
    )
}

final class DiskScanner: @unchecked Sendable {
    private let runner: CommandRunner
    private let smartctlExecutable: String?

    init(runner: CommandRunner) {
        self.runner = runner
        self.smartctlExecutable = firstExecutablePath(
            candidates: [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/smartctl").path,
                "/opt/homebrew/sbin/smartctl",
                "/usr/local/sbin/smartctl",
                "/usr/local/bin/smartctl",
                "/opt/local/sbin/smartctl"
            ],
            fileManager: FileManager.default
        )
    }

    func scan(onCommand: @escaping (String) -> Void) throws -> DiskSnapshot {
        let listResult = try runChecked(
            executable: "/usr/sbin/diskutil",
            arguments: ["list", "-plist", "external", "physical"],
            timeoutSeconds: 15,
            onCommand: onCommand
        )
        let listCommand = renderedCommand(
            executable: "/usr/sbin/diskutil",
            arguments: ["list", "-plist", "external", "physical"]
        )
        let diskList = try decodePropertyList(
            DiskListPropertyList.self,
            output: listResult.output,
            command: listCommand
        )

        return try externalDiskSnapshot(entries: diskList.disks) { entry in
            try self.scanExternalDisk(entry: entry, onCommand: onCommand)
        }
    }

    private func scanExternalDisk(
        entry: DiskListEntry,
        onCommand: @escaping (String) -> Void
    ) throws -> ScannedExternalDisk {
        let wholeInfo = try diskInfo(identifier: entry.identifier, onCommand: onCommand)
        if isVirtualUnlockerDisk(wholeInfo) {
            return .unlocker(
                try virtualUnlocker(
                    entry: entry,
                    wholeInfo: wholeInfo,
                    onCommand: onCommand
                )
            )
        }
        var volumes: [ExternalVolume] = []

        if entry.partitions.isEmpty, wholeInfo.filesystemType != nil {
            volumes.append(
                externalVolume(
                    info: wholeInfo,
                    wholeDiskIdentifier: entry.identifier,
                    fallbackName: entry.identifier,
                    fallbackSize: entry.size,
                    apfsRecord: nil
                )
            )
        }

        for partition in entry.partitions {
            let partitionInfo = try diskInfo(identifier: partition.identifier, onCommand: onCommand)
            if let containerReference = nonEmpty(partitionInfo.apfsContainerReference) {
                let apfsVolumes = try volumesInAPFSContainer(
                    containerReference: containerReference,
                    wholeDiskIdentifier: entry.identifier,
                    onCommand: onCommand
                )
                volumes.append(contentsOf: apfsVolumes)
            } else if partitionInfo.filesystemType != nil {
                volumes.append(
                    externalVolume(
                        info: partitionInfo,
                        wholeDiskIdentifier: entry.identifier,
                        fallbackName: partition.identifier,
                        fallbackSize: partition.size,
                        apfsRecord: nil
                    )
                )
            }
        }

        let uniqueVolumes = Dictionary(grouping: volumes, by: \.identifier).compactMap { $0.value.first }
        let diskName = nonEmpty(wholeInfo.mediaName) ?? nonEmpty(wholeInfo.registryName) ?? entry.identifier
        let expandedSMART = try collectExpandedSMART(
            identifier: entry.identifier,
            onCommand: onCommand
        )
        return .disk(
            ExternalDisk(
                identifier: entry.identifier,
                name: diskName,
                deviceTreePath: nonEmpty(wholeInfo.deviceTreePath),
                busProtocol: nonEmpty(wholeInfo.busProtocol) ?? "Unknown",
                smartStatus: nonEmpty(wholeInfo.smartStatus) ?? "Unavailable",
                expandedSMART: expandedSMART,
                size: wholeInfo.totalSize ?? wholeInfo.size ?? entry.size,
                volumes: uniqueVolumes.sorted { $0.identifier < $1.identifier }
            )
        )
    }

    private func collectExpandedSMART(
        identifier: String,
        onCommand: @escaping (String) -> Void
    ) throws -> ExpandedSMART {
        guard let smartctlExecutable else {
            return .unavailable(
                reason: "the optional smartctl collector is not installed and native macOS exposed only overall SMART status"
            )
        }
        let arguments = ["--all", "--json", "/dev/\(identifier)"]
        let command = renderedCommand(executable: smartctlExecutable, arguments: arguments)
        onCommand(command)
        let result: CommandResult
        do {
            result = try runner.run(
                executable: smartctlExecutable,
                arguments: arguments,
                timeoutSeconds: 15
            ) { _ in }
        } catch TroubleshooterError.cancelled {
            throw TroubleshooterError.cancelled
        } catch let error as TroubleshooterError {
            return .unavailable(reason: error.localizedDescription)
        }
        do {
            return try decodeExpandedSMART(
                output: result.output,
                command: command,
                collector: smartctlExecutable,
                exitStatus: result.exitStatus
            )
        } catch let error as TroubleshooterError {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    private func virtualUnlocker(
        entry: DiskListEntry,
        wholeInfo: DiskInfoPropertyList,
        onCommand: @escaping (String) -> Void
    ) throws -> VirtualUnlocker {
        let partitionInfos = try flattenedPartitions(entry.partitions).map { partition in
            try diskInfo(identifier: partition.identifier, onCommand: onCommand)
        }
        let mountedInfo = partitionInfos.first { nonEmpty($0.mountPoint) != nil }
        let name = nonEmpty(mountedInfo?.volumeName)
            ?? nonEmpty(wholeInfo.registryName)
            ?? nonEmpty(wholeInfo.mediaName)
            ?? entry.identifier
        return VirtualUnlocker(
            wholeDiskIdentifier: entry.identifier,
            volumeIdentifier: mountedInfo?.identifier,
            name: name,
            mountPoint: nonEmpty(mountedInfo?.mountPoint),
            deviceTreePath: nonEmpty(wholeInfo.deviceTreePath)
        )
    }

    func diskInfo(identifier: String, onCommand: @escaping (String) -> Void) throws -> DiskInfoPropertyList {
        let arguments = ["info", "-plist", "/dev/\(identifier)"]
        let result = try runChecked(
            executable: "/usr/sbin/diskutil",
            arguments: arguments,
            timeoutSeconds: 15,
            onCommand: onCommand
        )
        return try decodePropertyList(
            DiskInfoPropertyList.self,
            output: result.output,
            command: renderedCommand(executable: "/usr/sbin/diskutil", arguments: arguments)
        )
    }

    private func volumesInAPFSContainer(
        containerReference: String,
        wholeDiskIdentifier: String,
        onCommand: @escaping (String) -> Void
    ) throws -> [ExternalVolume] {
        let arguments = ["apfs", "list", "-plist", "/dev/\(containerReference)"]
        let result = try runChecked(
            executable: "/usr/sbin/diskutil",
            arguments: arguments,
            timeoutSeconds: 15,
            onCommand: onCommand
        )
        let plist = try decodePropertyList(
            APFSListPropertyList.self,
            output: result.output,
            command: renderedCommand(executable: "/usr/sbin/diskutil", arguments: arguments)
        )
        guard let container = plist.containers.first(where: { $0.reference == containerReference }) else {
            throw TroubleshooterError.invalidPropertyList(
                command: renderedCommand(executable: "/usr/sbin/diskutil", arguments: arguments),
                reason: "container \(containerReference) was absent from its own response"
            )
        }

        return try container.volumes.filter(isUserFacingAPFSVolume).map { record in
            let info = try diskInfo(identifier: record.identifier, onCommand: onCommand)
            return externalVolume(
                info: info,
                wholeDiskIdentifier: wholeDiskIdentifier,
                fallbackName: record.name,
                fallbackSize: record.capacityInUse,
                apfsRecord: record
            )
        }
    }

    private func externalVolume(
        info: DiskInfoPropertyList,
        wholeDiskIdentifier: String,
        fallbackName: String,
        fallbackSize: Int64,
        apfsRecord: APFSVolumeRecord?
    ) -> ExternalVolume {
        let roles = apfsRecord?.roles.joined(separator: ", ")
        return ExternalVolume(
            identifier: info.identifier,
            wholeDiskIdentifier: wholeDiskIdentifier,
            name: nonEmpty(info.volumeName) ?? nonEmpty(apfsRecord?.name) ?? fallbackName,
            filesystem: nonEmpty(info.filesystemName) ?? nonEmpty(info.filesystemType) ?? "Unknown",
            mountPoint: nonEmpty(info.mountPoint),
            isEncrypted: (apfsRecord?.encryption ?? false) || (apfsRecord?.fileVault ?? false) || (info.encryption ?? false) || (info.fileVault ?? false),
            isLocked: (apfsRecord?.locked ?? false) || (info.locked ?? false),
            isWritable: info.writableVolume ?? false,
            role: nonEmpty(roles),
            size: info.totalSize ?? info.size ?? fallbackSize
        )
    }

    private func runChecked(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        onCommand: @escaping (String) -> Void
    ) throws -> CommandResult {
        let command = renderedCommand(executable: executable, arguments: arguments)
        onCommand(command)
        let result = try runner.run(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        ) { _ in }
        guard result.exitStatus == 0 else {
            throw TroubleshooterError.commandFailed(
                command: command,
                exitStatus: result.exitStatus,
                output: result.output
            )
        }
        return result
    }
}

func firstExecutablePath(candidates: [String], fileManager: FileManager) -> String? {
    candidates.first { fileManager.isExecutableFile(atPath: $0) }
}

enum DiskArbitrationEvent: Equatable, Sendable {
    case appeared(identifier: String)
    case disappeared(identifier: String)
}

private let diskAppearedCallback: DADiskAppearedCallback = { disk, context in
    guard let context, let bsdName = DADiskGetBSDName(disk) else {
        return
    }
    let monitor = Unmanaged<DiskEventMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handle(.appeared(identifier: String(cString: bsdName)))
}

private let diskDisappearedCallback: DADiskDisappearedCallback = { disk, context in
    guard let context, let bsdName = DADiskGetBSDName(disk) else {
        return
    }
    let monitor = Unmanaged<DiskEventMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handle(.disappeared(identifier: String(cString: bsdName)))
}

final class DiskEventMonitor {
    private let handler: @Sendable (DiskArbitrationEvent) -> Void
    private var session: DASession?

    init(handler: @escaping @Sendable (DiskArbitrationEvent) -> Void) {
        self.handler = handler
    }

    func start() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw TroubleshooterError.commandLaunchFailed(
                executable: "Disk Arbitration session",
                reason: "DASessionCreate returned nil"
            )
        }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappearedCallback, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func handle(_ event: DiskArbitrationEvent) {
        handler(event)
    }

    deinit {
        guard let session else {
            return
        }
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }
}
