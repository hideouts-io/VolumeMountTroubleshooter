import DiskArbitration
import Foundation

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
        if isCancelled() {
            throw TroubleshooterError.cancelled
        }
        return CommandResult(exitStatus: process.terminationStatus, output: completeOutput)
    }
}

final class DiskScanner: @unchecked Sendable {
    private let runner: CommandRunner

    init(runner: CommandRunner) {
        self.runner = runner
    }

    func scan(onCommand: @escaping (String) -> Void) throws -> DiskSnapshot {
        let listResult = try runChecked(
            executable: "/usr/sbin/diskutil",
            arguments: ["list", "-plist", "external", "physical"],
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

        var disks: [ExternalDisk] = []
        for entry in diskList.disks {
            let wholeInfo = try diskInfo(identifier: entry.identifier, onCommand: onCommand)
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
            disks.append(
                ExternalDisk(
                    identifier: entry.identifier,
                    name: diskName,
                    busProtocol: nonEmpty(wholeInfo.busProtocol) ?? "Unknown",
                    smartStatus: nonEmpty(wholeInfo.smartStatus) ?? "Unavailable",
                    size: wholeInfo.totalSize ?? wholeInfo.size ?? entry.size,
                    volumes: uniqueVolumes.sorted { $0.identifier < $1.identifier }
                )
            )
        }
        return DiskSnapshot(disks: disks.sorted { $0.identifier < $1.identifier })
    }

    func diskInfo(identifier: String, onCommand: @escaping (String) -> Void) throws -> DiskInfoPropertyList {
        let arguments = ["info", "-plist", "/dev/\(identifier)"]
        let result = try runChecked(
            executable: "/usr/sbin/diskutil",
            arguments: arguments,
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
        onCommand: @escaping (String) -> Void
    ) throws -> CommandResult {
        let command = renderedCommand(executable: executable, arguments: arguments)
        onCommand(command)
        let result = try runner.run(executable: executable, arguments: arguments) { _ in }
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

private let diskAppearedCallback: DADiskAppearedCallback = { disk, context in
    guard let context, let bsdName = DADiskGetBSDName(disk) else {
        return
    }
    let monitor = Unmanaged<DiskArrivalMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.diskAppeared(identifier: String(cString: bsdName))
}

final class DiskArrivalMonitor {
    private let handler: @Sendable (String) -> Void
    private var session: DASession?

    init(handler: @escaping @Sendable (String) -> Void) {
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
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func diskAppeared(identifier: String) {
        handler(identifier)
    }

    deinit {
        guard let session else {
            return
        }
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }
}
