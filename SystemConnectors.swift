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

    func contains(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return output.contains(text)
    }
}

final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?
    private var commandInProgress = false
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
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func isCancelled() -> Bool {
        lock.lock()
        let result = cancellationRequested
        lock.unlock()
        return result
    }

    func isActiveCommand(executable: String, arguments: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard commandInProgress, let process = currentProcess else {
            return false
        }
        return process.executableURL?.path == executable && process.arguments == arguments
    }

    func run(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        onOutput: @escaping (String) -> Void
    ) throws -> CommandResult {
        try run(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            onLaunch: {},
            onOutput: onOutput
        )
    }

    func run(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        onLaunch: () -> Void,
        onOutput: @escaping (String) -> Void
    ) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let command = renderedCommand(executable: executable, arguments: arguments)
        let readHandle = outputPipe.fileHandleForReading
        let descriptor = readHandle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags != -1, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            let code = errno
            throw TroubleshooterError.commandOutputFailed(
                command: command,
                reason: "Could not configure nonblocking output reads (errno \(code)): \(String(cString: strerror(code)))"
            )
        }

        defer {
            lock.lock()
            if currentProcess === process {
                commandInProgress = false
                if !process.isRunning {
                    currentProcess = nil
                }
            }
            lock.unlock()
        }

        let processFinished = DispatchGroup()
        processFinished.enter()
        process.terminationHandler = { _ in
            processFinished.leave()
        }

        lock.lock()
        guard !commandInProgress else {
            lock.unlock()
            processFinished.leave()
            throw TroubleshooterError.commandLaunchFailed(
                executable: executable,
                reason: "This command runner is still collecting another command. Wait for its result before trying again."
            )
        }
        if let pendingProcess = currentProcess {
            guard !pendingProcess.isRunning else {
                lock.unlock()
                processFinished.leave()
                throw TroubleshooterError.commandLaunchFailed(
                    executable: executable,
                    reason: "The previous helper (PID \(pendingProcess.processIdentifier)) has not exited after termination. Wait for it to exit before trying again."
                )
            }
            currentProcess = nil
        }
        guard !cancellationRequested else {
            lock.unlock()
            processFinished.leave()
            throw TroubleshooterError.cancelled
        }
        do {
            try process.run()
            currentProcess = process
            commandInProgress = true
            lock.unlock()
        } catch {
            lock.unlock()
            processFinished.leave()
            throw TroubleshooterError.commandLaunchFailed(
                executable: executable,
                reason: error.localizedDescription
            )
        }
        onLaunch()

        let outputBuffer = CommandOutputBuffer()
        var failure = collectCommandOutput(
            descriptor: descriptor,
            processFinished: processFinished,
            outputBuffer: outputBuffer,
            command: command,
            timeoutSeconds: timeoutSeconds,
            isCancelled: { self.isCancelled() },
            onOutput: onOutput
        )
        if let originalFailure = failure,
           let terminationFailure = finishCommandProcess(process: process, finished: processFinished, command: command) {
            failure = .commandTerminationFailed(
                command: command,
                reason: "\(originalFailure.localizedDescription) Cleanup also failed: \(terminationFailure.localizedDescription)"
            )
        }
        do {
            try readHandle.close()
        } catch {
            let originalFailure = failure.map { "\($0.localizedDescription) " } ?? ""
            failure = .commandOutputFailed(
                command: command,
                reason: "\(originalFailure)Could not close the command's output pipe: \(error.localizedDescription)"
            )
        }
        if isCancelled() {
            switch failure {
            case nil, .commandTimedOut?:
                failure = .cancelled
            default:
                break
            }
        }
        if let failure {
            throw failure
        }
        return CommandResult(
            exitStatus: process.terminationStatus,
            output: try outputBuffer.value(command: command)
        )
    }
}

/// One reader owns the pipe until EOF or failure; the deadline covers both child exit and complete output.
private func collectCommandOutput(
    descriptor: Int32,
    processFinished: DispatchGroup,
    outputBuffer: CommandOutputBuffer,
    command: String,
    timeoutSeconds: TimeInterval,
    isCancelled: () -> Bool,
    onOutput: (String) -> Void
) -> TroubleshooterError? {
    let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
    var reachedEOF = false
    var bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
        if isCancelled() {
            return .cancelled
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            return .commandTimedOut(command: command, timeoutSeconds: timeoutSeconds)
        }
        if reachedEOF, processFinished.wait(timeout: .now()) == .success {
            return nil
        }
        let interval = min(0.05, remaining)
        if reachedEOF {
            _ = processFinished.wait(timeout: .now() + interval)
            continue
        }
        var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = Darwin.poll(&event, 1, Int32(ceil(interval * 1_000)))
        if ready < 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            return .commandOutputFailed(command: command, reason: "Output poll failed (errno \(code)): \(String(cString: strerror(code)))")
        }
        if isCancelled() {
            return .cancelled
        }
        guard ready > 0 else { continue }
        if event.revents & Int16(POLLNVAL) != 0 {
            return .commandOutputFailed(command: command, reason: "The command's output descriptor became invalid while collecting output.")
        }
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        if count < 0 {
            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                continue
            }
            return .commandOutputFailed(command: command, reason: "Output read failed (errno \(code)): \(String(cString: strerror(code)))")
        }
        if count == 0 {
            reachedEOF = true
            continue
        }
        let chunk = outputBuffer.append(Data(bytes.prefix(count)))
        if !chunk.isEmpty {
            onOutput(chunk)
        }
    }
}

/// Keep both termination waits finite and retain a live Process in its runner if cleanup cannot complete.
private func finishCommandProcess(process: Process, finished: DispatchGroup, command: String) -> TroubleshooterError? {
    if finished.wait(timeout: .now()) == .success {
        return nil
    }
    if process.isRunning {
        process.terminate()
    }
    if finished.wait(timeout: .now() + 2) == .success {
        return nil
    }
    if process.isRunning, Darwin.kill(process.processIdentifier, SIGKILL) != 0 {
        let code = errno
        if code != ESRCH {
            return .commandTerminationFailed(command: command, reason: "Could not stop helper PID \(process.processIdentifier) (errno \(code)): \(String(cString: strerror(code)))")
        }
    }
    guard finished.wait(timeout: .now() + 2) == .success else {
        return .commandTerminationFailed(command: command, reason: "Helper PID \(process.processIdentifier) did not acknowledge exit within two seconds after SIGKILL. Its runner remains unavailable until it exits.")
    }
    return nil
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
        var launchCount = 0
        var activeCommandWasPublished = false
        let launched = try runner.run(
            executable: "/usr/bin/true",
            arguments: [],
            timeoutSeconds: 5,
            onLaunch: {
                launchCount += 1
                activeCommandWasPublished = runner.isActiveCommand(executable: "/usr/bin/true", arguments: [])
            },
            onOutput: { _ in }
        )
        guard launched.exitStatus == 0, launchCount == 1, activeCommandWasPublished else {
            try fileManager.removeItem(at: directory)
            return false
        }
        let preCancelledRunner = CommandRunner()
        preCancelledRunner.cancel()
        var cancelledLaunchCount = 0
        do {
            _ = try preCancelledRunner.run(
                executable: "/usr/bin/true",
                arguments: [],
                timeoutSeconds: 5,
                onLaunch: { cancelledLaunchCount += 1 },
                onOutput: { _ in }
            )
            try fileManager.removeItem(at: directory)
            return false
        } catch TroubleshooterError.cancelled {
            guard cancelledLaunchCount == 0 else {
                try fileManager.removeItem(at: directory)
                return false
            }
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
        let bulkStream = CommandOutputBuffer()
        let bulk = try runner.run(
            executable: "/usr/bin/awk",
            arguments: ["BEGIN { for (i = 0; i < 131072; i++) printf \"x\" }"],
            timeoutSeconds: 5
        ) { chunk in
            _ = bulkStream.append(Data(chunk.utf8))
        }
        guard bulk.exitStatus == 0,
              bulk.output == String(repeating: "x", count: 131_072),
              try bulkStream.value(command: "complete pipe drain self-test") == bulk.output else {
            throw TroubleshooterError.invalidCommandOutput(command: "complete pipe drain self-test", reason: "Buffered output was truncated or streaming disagreed with captured output")
        }

        let heldStream = CommandOutputBuffer()
        let heldStarted = ProcessInfo.processInfo.systemUptime
        do {
            _ = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", #"(/bin/sleep 3) & printf 'parent-complete\n'"#],
                timeoutSeconds: 1
            ) { chunk in
                _ = heldStream.append(Data(chunk.utf8))
            }
            throw TroubleshooterError.invalidCommandOutput(command: "inherited output deadline self-test", reason: "The runner returned success before output reached EOF")
        } catch TroubleshooterError.commandTimedOut {
            guard ProcessInfo.processInfo.systemUptime - heldStarted < 2 else {
                throw TroubleshooterError.invalidCommandOutput(command: "inherited output deadline self-test", reason: "The runner waited for the descendant instead of its deadline")
            }
            guard try heldStream.value(command: "inherited output deadline self-test") == "parent-complete\n" else {
                throw TroubleshooterError.invalidCommandOutput(command: "inherited output deadline self-test", reason: "The parent command did not produce its complete output before the deadline")
            }
        }

        let heldTimeoutStarted = ProcessInfo.processInfo.systemUptime
        do {
            _ = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", #"(trap '' TERM; /bin/sleep 2) & exec /bin/sleep 30"#],
                timeoutSeconds: 0.1
            ) { _ in }
            throw TroubleshooterError.invalidCommandOutput(command: "timeout with inherited output self-test", reason: "The command did not time out")
        } catch TroubleshooterError.commandTimedOut {
            guard ProcessInfo.processInfo.systemUptime - heldTimeoutStarted < 1 else {
                throw TroubleshooterError.invalidCommandOutput(command: "timeout with inherited output self-test", reason: "The runner waited for the descendant's output after stopping its child")
            }
        }

        let cancelledStream = CommandOutputBuffer()
        let heldCancellationStarted = ProcessInfo.processInfo.systemUptime
        do {
            _ = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", #"(trap '' TERM PIPE; printf 'held-cancel-ready\n'; /bin/sleep 2; printf 'late-output\n' 2>/dev/null) & exec /bin/sleep 30"#],
                timeoutSeconds: 5
            ) { chunk in
                _ = cancelledStream.append(Data(chunk.utf8))
                if chunk.contains("held-cancel-ready") {
                    runner.cancel()
                }
            }
            throw TroubleshooterError.invalidCommandOutput(command: "cancellation with inherited output self-test", reason: "The command did not report cancellation")
        } catch TroubleshooterError.cancelled {
            guard ProcessInfo.processInfo.systemUptime - heldCancellationStarted < 1 else {
                throw TroubleshooterError.invalidCommandOutput(command: "cancellation with inherited output self-test", reason: "The runner waited for the descendant's output after cancellation")
            }
            guard try cancelledStream.value(command: "cancellation with inherited output self-test") == "held-cancel-ready\n" else {
                throw TroubleshooterError.invalidCommandOutput(command: "cancellation with inherited output self-test", reason: "The runner collected output after cancellation or missed the ready output")
            }
        }
        runner.reset()
        let lateOutputAcknowledged = directory.appendingPathComponent("late-output-acknowledged")
        let trapStream = CommandOutputBuffer()
        let offThreadCallbacks = CommandOutputBuffer()
        let callerThread: pthread_t = pthread_self()
        do {
            _ = try runner.run(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    #"trap 'printf "late-output\n"; : > "$1"; exit 0' TERM; printf 'trap-cancel-ready\n'; while :; do :; done"#,
                    "late-output-test",
                    lateOutputAcknowledged.path
                ],
                timeoutSeconds: 5
            ) { chunk in
                _ = trapStream.append(Data(chunk.utf8))
                if pthread_equal(pthread_self(), callerThread) == 0 {
                    _ = offThreadCallbacks.append(Data("off-thread".utf8))
                }
                if trapStream.contains("trap-cancel-ready\n"), !runner.isCancelled() {
                    runner.cancel()
                }
            }
            throw TroubleshooterError.invalidCommandOutput(command: "late output after cancellation self-test", reason: "The command did not report cancellation")
        } catch TroubleshooterError.cancelled {
            guard fileManager.fileExists(atPath: lateOutputAcknowledged.path) else {
                throw TroubleshooterError.invalidCommandOutput(command: "late output after cancellation self-test", reason: "The tracked helper did not acknowledge its late output before returning")
            }
            guard try trapStream.value(command: "late output after cancellation self-test") == "trap-cancel-ready\n" else {
                throw TroubleshooterError.invalidCommandOutput(command: "late output after cancellation self-test", reason: "The runner delivered output after cancellation or missed the ready output")
            }
            guard try offThreadCallbacks.value(command: "late output after cancellation self-test") == "" else {
                throw TroubleshooterError.invalidCommandOutput(command: "late output after cancellation self-test", reason: "The runner invoked an output callback on another thread")
            }
        }
        runner.reset()
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
        runner.reset()
        let cancellationStarted = ProcessInfo.processInfo.systemUptime
        do {
            _ = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; printf 'cancel-ready\\n'; exec /bin/sleep 30"],
                timeoutSeconds: 5
            ) { chunk in
                if chunk.contains("cancel-ready") {
                    runner.cancel()
                }
            }
            try fileManager.removeItem(at: directory)
            return false
        } catch TroubleshooterError.cancelled {
            let cancellationElapsed = ProcessInfo.processInfo.systemUptime - cancellationStarted
            guard cancellationElapsed < 4 else {
                FileHandle.standardError.write(Data("Active cancellation waited for the original command deadline\n".utf8))
                try fileManager.removeItem(at: directory)
                return false
            }
        }
        runner.reset()
        do {
            _ = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"],
                timeoutSeconds: 0.1
            ) { _ in }
            try fileManager.removeItem(at: directory)
            return false
        } catch TroubleshooterError.commandTimedOut {
        }
        let recovered = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'recovered\\n'"],
            timeoutSeconds: 5
        ) { _ in }
        guard recovered.exitStatus == 0, recovered.output == "recovered\n" else {
            try fileManager.removeItem(at: directory)
            return false
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
            switch error {
            case .commandTerminationFailed, .commandOutputFailed:
                throw error
            default:
                break
            }
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
            switch error {
            case .commandTerminationFailed, .commandOutputFailed:
                throw error
            default:
                break
            }
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
