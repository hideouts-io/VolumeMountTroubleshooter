import DiskArbitration
import Darwin
import Foundation

private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var trailingBytes = Data()
    private var decodingFailure: String?

    func append(_ data: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard decodingFailure == nil else { return "" }
        let bytes = trailingBytes + data
        for retainedCount in 0...min(3, bytes.count) {
            if let text = String(data: bytes.dropLast(retainedCount), encoding: .utf8) {
                trailingBytes = Data(bytes.suffix(retainedCount))
                output.append(text)
                return text
            }
        }
        decodingFailure = "the command emitted invalid UTF-8; its output cannot be displayed reliably"
        return ""
    }

    func value(command: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let decodingFailure {
            throw TroubleshooterError.invalidCommandOutput(command: command, reason: decodingFailure)
        }
        guard trailingBytes.isEmpty else {
            throw TroubleshooterError.invalidCommandOutput(
                command: command,
                reason: "the command ended with an incomplete or invalid UTF-8 character"
            )
        }
        return output
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

        defer {
            lock.lock()
            currentProcess = nil
            lock.unlock()
        }

        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            processFinished.signal()
        }

        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            throw TroubleshooterError.cancelled
        }
        do {
            try process.run()
            currentProcess = process
            lock.unlock()
        } catch {
            lock.unlock()
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
                let chunk = outputBuffer.append(data)
                if !chunk.isEmpty {
                    onOutput(chunk)
                }
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
        return CommandResult(
            exitStatus: process.terminationStatus,
            output: try outputBuffer.value(command: renderedCommand(executable: executable, arguments: arguments))
        )
    }
}

/// Exercises actual pipe boundaries, command failure output and cancellation without touching storage devices.
func runCommandRunnerSelfTests() -> Bool {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent("volume-report-stream-\(UUID().uuidString)", isDirectory: true)
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let readyFile = directory.appendingPathComponent("reader-ready")
        let streamed = CommandOutputBuffer()
        let runner = CommandRunner()
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"printf 'prefix:\342'; while [ ! -e "$1" ]; do /bin/sleep 0.01; done; printf '\202\254 \360\237\222\276\n'"#,
                "stream-test",
                readyFile.path
            ],
            timeoutSeconds: 5
        ) { chunk in
            _ = streamed.append(Data(chunk.utf8))
            if chunk == "prefix:" {
                if !fileManager.createFile(atPath: readyFile.path, contents: Data()) {
                    FileHandle.standardError.write(Data("Could not create the task-owned pipe-test handshake file\n".utf8))
                }
            }
        }
        let streamedText = try streamed.value(command: "native pipe self-test")
        guard result.exitStatus == 0, result.output == "prefix:€ 💾\n", streamedText == result.output else {
            try fileManager.removeItem(at: directory)
            return false
        }
        let failure = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'specific command failure\\n'; exit 7"],
            timeoutSeconds: 5
        ) { _ in }
        guard failure.exitStatus == 7, failure.output == "specific command failure\n" else {
            try fileManager.removeItem(at: directory)
            return false
        }
        do {
            _ = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", #"printf '\377'"#],
                timeoutSeconds: 5
            ) { _ in }
            try fileManager.removeItem(at: directory)
            return false
        } catch TroubleshooterError.invalidCommandOutput {
        }
        runner.cancel()
        let forbiddenFile = directory.appendingPathComponent("cancelled-command-launched")
        do {
            _ = try runner.run(
                executable: "/usr/bin/touch",
                arguments: [forbiddenFile.path],
                timeoutSeconds: 5
            ) { _ in }
            try fileManager.removeItem(at: directory)
            return false
        } catch TroubleshooterError.cancelled {
            guard !fileManager.fileExists(atPath: forbiddenFile.path) else {
                try fileManager.removeItem(at: directory)
                return false
            }
        }
        try fileManager.removeItem(at: directory)
        return true
    } catch {
        FileHandle.standardError.write(Data("Command integration self-test failed: \(error.localizedDescription)\n".utf8))
        if fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                FileHandle.standardError.write(Data("Could not remove task-owned command-test directory: \(error.localizedDescription)\n".utf8))
            }
        }
        return false
    }
}

enum ScannedExternalDisk: Sendable {
    case disk(ExternalDisk)
    case unlocker(VirtualUnlocker)
}

struct SelectedStorageState {
    let volume: ExternalVolume
    let wholeDiskInfo: DiskInfoPropertyList
}

struct SelectedStorageEvidence {
    let state: SelectedStorageState
    let transport: PhysicalTransport
    let expandedSMART: ExpandedSMART
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
        let mediaIdentity = try collectMediaIdentity(identifier: entry.identifier)
        let wholeInfo = try diskInfo(identifier: entry.identifier, onCommand: onCommand)
        guard wholeInfo.parentWholeDisk == entry.identifier else {
            throw TroubleshooterError.invalidPropertyList(
                command: "diskutil info -plist /dev/\(entry.identifier)",
                reason: "the external physical inventory entry is not its own parent whole disk"
            )
        }
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
                    physicalStoreIdentifiers: [entry.identifier],
                    apfsRecord: nil
                )
            )
        }

        for partition in flattenedPartitions(entry.partitions) {
            let partitionInfo = try diskInfo(identifier: partition.identifier, onCommand: onCommand)
            guard partitionInfo.parentWholeDisk == entry.identifier else {
                throw TroubleshooterError.invalidPropertyList(
                    command: "diskutil info -plist /dev/\(partition.identifier)",
                    reason: "the scanned partition belongs to a different physical disk"
                )
            }
            if let containerReference = nonEmpty(partitionInfo.apfsContainerReference) {
                let apfsVolumes = try volumesInAPFSContainer(
                    containerReference: containerReference,
                    wholeDiskIdentifier: entry.identifier,
                    physicalStoreIdentifier: partition.identifier,
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
                        physicalStoreIdentifiers: [entry.identifier],
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
        let physicalTransport: PhysicalTransport
        switch mediaIdentity {
        case let .observed(expectedID):
            physicalTransport = try collectPhysicalTransport(info: wholeInfo, onCommand: onCommand)
            do {
                try verifyMediaContinuity(identifier: entry.identifier, expectedRegistryEntryID: expectedID)
            } catch let error as TransportScanError {
                throw TroubleshooterError.invalidPropertyList(
                    command: "IOKit identity revalidation for /dev/\(entry.identifier)",
                    reason: error.localizedDescription
                )
            }
        case let .unavailable(reason):
            physicalTransport = .unavailable(reason: "Initial block-media identity unavailable. \(reason)")
        }
        return .disk(
            ExternalDisk(
                identifier: entry.identifier,
                name: diskName,
                deviceTreePath: nonEmpty(wholeInfo.deviceTreePath),
                busProtocol: nonEmpty(wholeInfo.busProtocol) ?? "Unknown",
                smartStatus: nonEmpty(wholeInfo.smartStatus) ?? "Unavailable",
                expandedSMART: expandedSMART,
                mediaIdentity: mediaIdentity,
                physicalTransport: physicalTransport,
                size: wholeInfo.totalSize ?? wholeInfo.size ?? entry.size,
                volumes: uniqueVolumes.sorted { $0.identifier < $1.identifier }
            )
        )
    }

    private func collectMediaIdentity(identifier: String) throws -> PhysicalMediaIdentity {
        do {
            return .observed(registryEntryID: try TransportScanner(runner: runner).mediaRegistryEntryID(diskIdentifier: identifier))
        } catch let error as TransportScanError {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    private func verifyMediaContinuity(identifier: String, expectedRegistryEntryID: UInt64) throws {
        let currentID = try TransportScanner(runner: runner).mediaRegistryEntryID(diskIdentifier: identifier)
        guard currentID == expectedRegistryEntryID else {
            throw TransportScanError.invalidObservation(reason: "the BSD disk number was reused by a different IOMedia service during collection; refresh and select again")
        }
    }

    private func collectPhysicalTransport(
        info: DiskInfoPropertyList,
        onCommand: @escaping (String) -> Void
    ) throws -> PhysicalTransport {
        onCommand("IOKit: exact IOMedia BSD match and IOService ancestry for /dev/\(info.identifier)")
        do {
            let path = try TransportScanner(runner: runner).scan(
                diskIdentifier: info.identifier,
                busProtocol: nonEmpty(info.busProtocol) ?? "Unknown",
                expectedDeviceTreePath: nonEmpty(info.deviceTreePath)
            )
            return .observed(path)
        } catch let error as TransportScanError {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// Requires the captured media identity and current backing-store mapping to agree before using disk numbers.
    func validatedSelectedStorage(
        volume: ExternalVolume,
        disk: ExternalDisk,
        onCommand: @escaping (String) -> Void
    ) throws -> SelectedStorageState {
        try validateCapturedMediaIdentity(disk: disk)
        let selectedInfo = try diskInfo(identifier: volume.identifier, onCommand: onCommand)
        guard selectedInfo.identifier == volume.identifier else {
            throw TroubleshooterError.selectedStorageChanged(reason: "diskutil returned a different selected volume")
        }
        let currentStores: [String]
        let apfsRecord: APFSVolumeRecord?
        if let reference = nonEmpty(selectedInfo.apfsContainerReference) {
            let container = try apfsContainer(reference: reference, onCommand: onCommand)
            let matchingVolumes = container.volumes.filter { $0.identifier == volume.identifier }
            guard matchingVolumes.count == 1, let record = matchingVolumes.first else {
                throw TroubleshooterError.selectedStorageChanged(reason: "the selected APFS volume is absent or duplicated in its current container")
            }
            currentStores = container.physicalStores.map(\.identifier)
            apfsRecord = record
        } else if let whole = nonEmpty(selectedInfo.parentWholeDisk) {
            currentStores = [whole]
            apfsRecord = nil
        } else {
            throw TroubleshooterError.selectedStorageChanged(reason: "diskutil did not expose the selected volume's parent whole disk")
        }
        guard currentStores.count == 1 else {
            throw TroubleshooterError.unsupportedStorage(reason: "the selected APFS volume spans multiple physical stores; no single disk or path can be attributed")
        }
        guard Set(currentStores) == Set(volume.physicalStoreIdentifiers),
            singleBackingWholeDisk(volume) == disk.identifier
        else {
            throw TroubleshooterError.selectedStorageChanged(reason: "the selected volume's physical-store mapping changed")
        }
        let storeInfo = try diskInfo(identifier: currentStores[0], onCommand: onCommand)
        guard storeInfo.parentWholeDisk == disk.identifier else {
            throw TroubleshooterError.selectedStorageChanged(reason: "the selected physical store no longer belongs to /dev/\(disk.identifier)")
        }
        let wholeInfo = currentStores[0] == disk.identifier
            ? storeInfo
            : try diskInfo(identifier: disk.identifier, onCommand: onCommand)
        guard wholeInfo.identifier == disk.identifier, wholeInfo.deviceTreePath == disk.deviceTreePath else {
            throw TroubleshooterError.selectedStorageChanged(reason: "the selected physical disk's identity or physical path changed")
        }
        try validateCapturedMediaIdentity(disk: disk)
        return SelectedStorageState(
            volume: externalVolume(
                info: selectedInfo,
                wholeDiskIdentifier: disk.identifier,
                fallbackName: volume.identifier,
                fallbackSize: 0,
                physicalStoreIdentifiers: currentStores,
                apfsRecord: apfsRecord
            ),
            wholeDiskInfo: wholeInfo
        )
    }

    private func validateCapturedMediaIdentity(disk: ExternalDisk) throws {
        guard case let .observed(expectedID) = disk.mediaIdentity else {
            throw TroubleshooterError.selectedStorageChanged(reason: "no exact block-media identity was captured when this disk was selected")
        }
        do {
            try verifyMediaContinuity(identifier: disk.identifier, expectedRegistryEntryID: expectedID)
        } catch let error as TransportScanError {
            throw TroubleshooterError.selectedStorageChanged(reason: error.localizedDescription)
        }
    }

    func currentPhysicalTransport(
        volume: ExternalVolume,
        disk: ExternalDisk,
        onCommand: @escaping (String) -> Void
    ) throws -> PhysicalTransport {
        let state = try validatedSelectedStorage(volume: volume, disk: disk, onCommand: onCommand)
        let transport = try collectPhysicalTransport(info: state.wholeDiskInfo, onCommand: onCommand)
        try validateCapturedMediaIdentity(disk: disk)
        return transport
    }

    func currentSelectedStorageEvidence(
        volume: ExternalVolume,
        disk: ExternalDisk,
        onCommand: @escaping (String) -> Void
    ) throws -> SelectedStorageEvidence {
        let state = try validatedSelectedStorage(volume: volume, disk: disk, onCommand: onCommand)
        let transport = try collectPhysicalTransport(info: state.wholeDiskInfo, onCommand: onCommand)
        let expandedSMART = try collectExpandedSMART(identifier: disk.identifier, onCommand: onCommand)
        try validateCapturedMediaIdentity(disk: disk)
        return SelectedStorageEvidence(state: state, transport: transport, expandedSMART: expandedSMART)
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
        guard wholeDiskIdentifier(forPhysicalStore: identifier) != nil else {
            throw TroubleshooterError.invalidPropertyList(command: "diskutil info -plist", reason: "an invalid BSD disk or partition identifier was supplied")
        }
        let arguments = ["info", "-plist", "/dev/\(identifier)"]
        let result = try runChecked(
            executable: "/usr/sbin/diskutil",
            arguments: arguments,
            timeoutSeconds: 15,
            onCommand: onCommand
        )
        let info = try decodePropertyList(
            DiskInfoPropertyList.self,
            output: result.output,
            command: renderedCommand(executable: "/usr/sbin/diskutil", arguments: arguments)
        )
        guard info.identifier == identifier else {
            throw TroubleshooterError.invalidPropertyList(
                command: renderedCommand(executable: "/usr/sbin/diskutil", arguments: arguments),
                reason: "the response's DeviceIdentifier does not match the requested BSD identifier"
            )
        }
        return info
    }

    private func volumesInAPFSContainer(
        containerReference: String,
        wholeDiskIdentifier: String,
        physicalStoreIdentifier: String,
        onCommand: @escaping (String) -> Void
    ) throws -> [ExternalVolume] {
        let container = try apfsContainer(reference: containerReference, onCommand: onCommand)
        guard container.physicalStores.contains(where: { $0.identifier == physicalStoreIdentifier }) else {
            throw TroubleshooterError.invalidPropertyList(
                command: "diskutil apfs list -plist /dev/\(containerReference)",
                reason: "the scanned partition is absent from this container's physical stores"
            )
        }
        guard container.physicalStores.count == 1 else {
            throw TroubleshooterError.unsupportedStorage(
                reason: "APFS container /dev/\(containerReference) spans multiple physical stores; selecting one backing disk would be ambiguous"
            )
        }
        return try container.volumes.filter(isUserFacingAPFSVolume).map { record in
            let info = try diskInfo(identifier: record.identifier, onCommand: onCommand)
            return externalVolume(
                info: info,
                wholeDiskIdentifier: wholeDiskIdentifier,
                fallbackName: record.name,
                fallbackSize: record.capacityInUse,
                physicalStoreIdentifiers: container.physicalStores.map(\.identifier),
                apfsRecord: record
            )
        }
    }

    private func apfsContainer(
        reference: String,
        onCommand: @escaping (String) -> Void
    ) throws -> APFSContainerRecord {
        guard wholeDiskIdentifier(forPhysicalStore: reference) == reference else {
            throw TroubleshooterError.invalidPropertyList(command: "diskutil apfs list -plist", reason: "an invalid APFS container BSD identifier was supplied")
        }
        let arguments = ["apfs", "list", "-plist", "/dev/\(reference)"]
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
        let matches = plist.containers.filter { $0.reference == reference }
        guard matches.count == 1, let container = matches.first else {
            throw TroubleshooterError.invalidPropertyList(
                command: renderedCommand(executable: "/usr/sbin/diskutil", arguments: arguments),
                reason: "container \(reference) was absent or duplicated in its own response"
            )
        }

        guard
            !container.physicalStores.isEmpty,
            container.physicalStores.count <= 32,
            Set(container.physicalStores.map(\.identifier)).count == container.physicalStores.count,
            container.physicalStores.allSatisfy({ wholeDiskIdentifier(forPhysicalStore: $0.identifier) != nil })
        else {
            throw TroubleshooterError.invalidPropertyList(
                command: renderedCommand(executable: "/usr/sbin/diskutil", arguments: arguments),
                reason: "APFS physical stores are absent, duplicated, invalid or exceed the supported bound"
            )
        }
        return container
    }

    private func externalVolume(
        info: DiskInfoPropertyList,
        wholeDiskIdentifier: String,
        fallbackName: String,
        fallbackSize: Int64,
        physicalStoreIdentifiers: [String],
        apfsRecord: APFSVolumeRecord?
    ) -> ExternalVolume {
        let roles = apfsRecord?.roles.joined(separator: ", ")
        return ExternalVolume(
            identifier: info.identifier,
            wholeDiskIdentifier: wholeDiskIdentifier,
            physicalStoreIdentifiers: physicalStoreIdentifiers,
            name: nonEmpty(info.volumeName) ?? nonEmpty(apfsRecord?.name) ?? fallbackName,
            filesystem: nonEmpty(info.filesystemName) ?? nonEmpty(info.filesystemType) ?? "Unknown",
            mountPoint: nonEmpty(info.mountPoint),
            isEncrypted: observedEncryptionState(info: info, apfsRecord: apfsRecord),
            isLocked: apfsRecord?.locked ?? info.locked,
            isWritable: info.writableVolume,
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
        onCommand("[exit status: \(result.exitStatus)]")
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
