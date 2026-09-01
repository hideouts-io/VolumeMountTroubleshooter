import Foundation

struct CommandResult: Sendable {
    let exitStatus: Int32
    let output: String
}

struct ExternalVolume: Hashable, Sendable {
    let identifier: String
    let wholeDiskIdentifier: String
    let name: String
    let filesystem: String
    let mountPoint: String?
    let isEncrypted: Bool
    let isLocked: Bool
    let isWritable: Bool
    let role: String?
    let size: Int64
}

struct ExternalDisk: Hashable, Sendable {
    let identifier: String
    let name: String
    let deviceTreePath: String?
    let busProtocol: String
    let smartStatus: String
    let expandedSMART: ExpandedSMART
    let size: Int64
    let volumes: [ExternalVolume]
}

enum SMARTDataSource: String, Hashable, Sendable {
    case nvme = "NVMe SMART/Health log"
    case ata = "ATA vendor SMART attributes"
    case scsi = "SCSI/bridge health data"
    case unknown = "drive or bridge health data"
}

struct SMARTMetrics: Hashable, Sendable {
    let temperatureCelsius: Int?
    let mediaErrors: UInt64?
    let unsafeShutdowns: UInt64?
    let powerOnHours: UInt64?
    let percentageUsed: Int?
    let source: SMARTDataSource
    let collector: String
    let collectorExitStatus: Int32
}

enum ExpandedSMART: Hashable, Sendable {
    case reported(SMARTMetrics)
    case unavailable(reason: String)
}

struct VolumeActionAvailability: Equatable, Sendable {
    let inspect: Bool
    let mountReadOnly: Bool
    let mountNormally: Bool
    let unmountVolume: Bool
    let safeEjectDisk: Bool
}

func volumeActionAvailability(for volume: ExternalVolume?) -> VolumeActionAvailability {
    guard let volume else {
        return VolumeActionAvailability(
            inspect: false,
            mountReadOnly: false,
            mountNormally: false,
            unmountVolume: false,
            safeEjectDisk: false
        )
    }
    let isMounted = nonEmpty(volume.mountPoint) != nil
    return VolumeActionAvailability(
        inspect: true,
        mountReadOnly: !volume.isLocked && (!isMounted || volume.isWritable),
        mountNormally: !volume.isLocked && !isMounted,
        unmountVolume: isMounted,
        safeEjectDisk: true
    )
}

struct VirtualUnlocker: Hashable, Sendable {
    let wholeDiskIdentifier: String
    let volumeIdentifier: String?
    let name: String
    let mountPoint: String?
    let deviceTreePath: String?
}

struct DiskScanFailure: Hashable, Sendable {
    let diskIdentifier: String
    let errorDescription: String
}

enum UnlockTransitionPhase: Equatable, Sendable {
    case detected
    case waiting
    case retry(attempt: Int, limit: Int)
    case ready(volumeName: String)
    case exhausted(limit: Int)

    var message: String {
        switch self {
        case .detected:
            return "Unlocker detected"
        case .waiting:
            return "Unlocker detected → Waiting for data disk"
        case let .retry(attempt, limit):
            return "Unlocker detected → Waiting for data disk (retry \(attempt) of \(limit))"
        case let .ready(volumeName):
            return "Unlocker detected → Waiting for data disk → \(volumeName) ready"
        case let .exhausted(limit):
            return "Unlocker detected → Waiting for data disk → Not detected after \(limit) retries"
        }
    }
}

struct DiskSnapshot: Sendable {
    let disks: [ExternalDisk]
    let unlockers: [VirtualUnlocker]
    let scanFailures: [DiskScanFailure]

    var volumes: [ExternalVolume] {
        disks.flatMap(\.volumes).sorted {
            if $0.name == $1.name {
                return $0.identifier < $1.identifier
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func disk(containing volume: ExternalVolume) -> ExternalDisk? {
        disks.first { $0.identifier == volume.wholeDiskIdentifier }
    }

    func dataVolume(matching unlocker: VirtualUnlocker) -> ExternalVolume? {
        guard let deviceTreePath = nonEmpty(unlocker.deviceTreePath) else {
            return nil
        }
        return disks
            .first { $0.deviceTreePath == deviceTreePath && !$0.volumes.isEmpty }?
            .volumes
            .first
    }

    func removingDevice(identifier: String) -> DiskSnapshot {
        let remainingDisks = disks.compactMap { disk -> ExternalDisk? in
            if deviceIdentifier(disk.identifier, isSameAsOrDescendantOf: identifier) {
                return nil
            }
            let remainingVolumes = disk.volumes.filter { volume in
                !deviceIdentifier(volume.identifier, isSameAsOrDescendantOf: identifier)
            }
            return ExternalDisk(
                identifier: disk.identifier,
                name: disk.name,
                deviceTreePath: disk.deviceTreePath,
                busProtocol: disk.busProtocol,
                smartStatus: disk.smartStatus,
                expandedSMART: disk.expandedSMART,
                size: disk.size,
                volumes: remainingVolumes
            )
        }
        let remainingUnlockers = unlockers.filter { unlocker in
            if deviceIdentifier(unlocker.wholeDiskIdentifier, isSameAsOrDescendantOf: identifier) {
                return false
            }
            guard let volumeIdentifier = unlocker.volumeIdentifier else {
                return true
            }
            return !deviceIdentifier(volumeIdentifier, isSameAsOrDescendantOf: identifier)
        }
        let remainingFailures = scanFailures.filter { failure in
            !deviceIdentifier(failure.diskIdentifier, isSameAsOrDescendantOf: identifier)
        }
        return DiskSnapshot(
            disks: remainingDisks,
            unlockers: remainingUnlockers,
            scanFailures: remainingFailures
        )
    }
}

enum TroubleshooterError: LocalizedError {
    case cancelled
    case commandLaunchFailed(executable: String, reason: String)
    case commandFailed(command: String, exitStatus: Int32, output: String)
    case commandTimedOut(command: String, timeoutSeconds: TimeInterval)
    case invalidPropertyList(command: String, reason: String)
    case invalidJSON(command: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Operation cancelled by the user"
        case let .commandLaunchFailed(executable, reason):
            return "Could not launch \(executable): \(reason)"
        case let .commandFailed(command, exitStatus, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command failed with exit status \(exitStatus): \(command)\n\(detail)"
        case let .commandTimedOut(command, timeoutSeconds):
            return "Command timed out after \(Int(timeoutSeconds)) seconds: \(command). The storage device may still be changing state; wait for the automatic rescan or press Refresh."
        case let .invalidPropertyList(command, reason):
            return "Could not decode structured output from \(command): \(reason)"
        case let .invalidJSON(command, reason):
            return "Could not decode structured JSON from \(command): \(reason)"
        }
    }
}

struct DiskListPropertyList: Decodable {
    let disks: [DiskListEntry]

    enum CodingKeys: String, CodingKey {
        case disks = "AllDisksAndPartitions"
    }
}

struct DiskListEntry: Decodable {
    let identifier: String
    let size: Int64
    let partitions: [DiskListPartition]

    enum CodingKeys: String, CodingKey {
        case identifier = "DeviceIdentifier"
        case size = "Size"
        case partitions = "Partitions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        size = try container.decode(Int64.self, forKey: .size)
        partitions = try container.decodeIfPresent([DiskListPartition].self, forKey: .partitions) ?? []
    }
}

struct DiskListPartition: Decodable {
    let identifier: String
    let size: Int64
    let partitions: [DiskListPartition]

    enum CodingKeys: String, CodingKey {
        case identifier = "DeviceIdentifier"
        case size = "Size"
        case partitions = "Partitions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        size = try container.decode(Int64.self, forKey: .size)
        partitions = try container.decodeIfPresent([DiskListPartition].self, forKey: .partitions) ?? []
    }
}

struct DiskInfoPropertyList: Decodable {
    let identifier: String
    let parentWholeDisk: String?
    let mediaName: String?
    let registryName: String?
    let volumeName: String?
    let filesystemType: String?
    let filesystemName: String?
    let mountPoint: String?
    let deviceTreePath: String?
    let busProtocol: String?
    let smartStatus: String?
    let size: Int64?
    let totalSize: Int64?
    let content: String?
    let apfsContainerReference: String?
    let encryption: Bool?
    let fileVault: Bool?
    let locked: Bool?
    let writableVolume: Bool?

    enum CodingKeys: String, CodingKey {
        case identifier = "DeviceIdentifier"
        case parentWholeDisk = "ParentWholeDisk"
        case mediaName = "MediaName"
        case registryName = "IORegistryEntryName"
        case volumeName = "VolumeName"
        case filesystemType = "FilesystemType"
        case filesystemName = "FilesystemName"
        case mountPoint = "MountPoint"
        case deviceTreePath = "DeviceTreePath"
        case busProtocol = "BusProtocol"
        case smartStatus = "SMARTStatus"
        case size = "Size"
        case totalSize = "TotalSize"
        case content = "Content"
        case apfsContainerReference = "APFSContainerReference"
        case encryption = "Encryption"
        case fileVault = "FileVault"
        case locked = "Locked"
        case writableVolume = "WritableVolume"
    }
}

private struct SmartctlDocument: Decodable {
    let device: SmartctlDevice?
    let temperature: SmartctlTemperature?
    let powerOnTime: SmartctlPowerOnTime?
    let nvmeHealth: SmartctlNVMeHealth?
    let ataAttributes: SmartctlATAAttributes?

    enum CodingKeys: String, CodingKey {
        case device
        case temperature
        case powerOnTime = "power_on_time"
        case nvmeHealth = "nvme_smart_health_information_log"
        case ataAttributes = "ata_smart_attributes"
    }
}

private struct SmartctlDevice: Decodable {
    let protocolName: String?

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
    }
}

private struct SmartctlTemperature: Decodable {
    let current: Int?
}

private struct SmartctlPowerOnTime: Decodable {
    let hours: UInt64?
}

private struct SmartctlNVMeHealth: Decodable {
    let temperature: Int?
    let percentageUsed: Int?
    let powerOnHours: UInt64?
    let unsafeShutdowns: UInt64?
    let mediaErrors: UInt64?

    enum CodingKeys: String, CodingKey {
        case temperature
        case percentageUsed = "percentage_used"
        case powerOnHours = "power_on_hours"
        case unsafeShutdowns = "unsafe_shutdowns"
        case mediaErrors = "media_errors"
    }
}

private struct SmartctlATAAttributes: Decodable {
    let table: [SmartctlATAAttribute]
}

private struct SmartctlATAAttribute: Decodable {
    let name: String
    let raw: SmartctlATARawValue
}

private struct SmartctlATARawValue: Decodable {
    let value: UInt64?
}

struct APFSListPropertyList: Decodable {
    let containers: [APFSContainerRecord]

    enum CodingKeys: String, CodingKey {
        case containers = "Containers"
    }
}

struct APFSContainerRecord: Decodable {
    let reference: String
    let volumes: [APFSVolumeRecord]

    enum CodingKeys: String, CodingKey {
        case reference = "ContainerReference"
        case volumes = "Volumes"
    }
}

struct APFSVolumeRecord: Decodable {
    let identifier: String
    let name: String
    let encryption: Bool
    let fileVault: Bool
    let locked: Bool
    let roles: [String]
    let capacityInUse: Int64

    enum CodingKeys: String, CodingKey {
        case identifier = "DeviceIdentifier"
        case name = "Name"
        case encryption = "Encryption"
        case fileVault = "FileVault"
        case locked = "Locked"
        case roles = "Roles"
        case capacityInUse = "CapacityInUse"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        encryption = try container.decodeIfPresent(Bool.self, forKey: .encryption) ?? false
        fileVault = try container.decodeIfPresent(Bool.self, forKey: .fileVault) ?? false
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        roles = try container.decodeIfPresent([String].self, forKey: .roles) ?? []
        capacityInUse = try container.decodeIfPresent(Int64.self, forKey: .capacityInUse) ?? 0
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

func decodePropertyList<T: Decodable>(_ type: T.Type, output: String, command: String) throws -> T {
    guard let data = output.data(using: .utf8) else {
        throw TroubleshooterError.invalidPropertyList(command: command, reason: "output was not UTF-8")
    }
    do {
        return try PropertyListDecoder().decode(type, from: data)
    } catch {
        throw TroubleshooterError.invalidPropertyList(command: command, reason: error.localizedDescription)
    }
}

func decodeExpandedSMART(
    output: String,
    command: String,
    collector: String,
    exitStatus: Int32
) throws -> ExpandedSMART {
    guard let data = output.data(using: .utf8) else {
        throw TroubleshooterError.invalidJSON(command: command, reason: "output was not UTF-8")
    }
    let document: SmartctlDocument
    do {
        document = try JSONDecoder().decode(SmartctlDocument.self, from: data)
    } catch {
        throw TroubleshooterError.invalidJSON(command: command, reason: error.localizedDescription)
    }

    let ataTable = document.ataAttributes?.table ?? []
    let temperature = document.temperature?.current
        ?? document.nvmeHealth?.temperature
        ?? intValue(
            ataRawValue(
                names: ["temperaturecelsius", "airflowtemperaturecel", "temperatureinternal"],
                attributes: ataTable
            )
        )
    let mediaErrors = document.nvmeHealth?.mediaErrors
        ?? ataRawValue(
            names: ["mediaanddataintegrityerrors", "reporteduncorrect", "offlineuncorrectable"],
            attributes: ataTable
        )
    let unsafeShutdowns = document.nvmeHealth?.unsafeShutdowns
        ?? ataRawValue(
            names: ["unsafeshutdowncount", "unexpectedpowerlosscount", "unexpectedpowerloss"],
            attributes: ataTable
        )
    let powerOnHours = document.powerOnTime?.hours
        ?? document.nvmeHealth?.powerOnHours
        ?? ataRawValue(
            names: ["poweronhours", "poweronhoursandmsec"],
            attributes: ataTable
        )
    let percentageUsed = document.nvmeHealth?.percentageUsed
        ?? intValue(
            ataRawValue(
                names: ["percentageused", "percentlifetimeused", "percentagelifetimeused", "ssdlifeused"],
                attributes: ataTable
            )
        )

    guard
        temperature != nil
            || mediaErrors != nil
            || unsafeShutdowns != nil
            || powerOnHours != nil
            || percentageUsed != nil
    else {
        return .unavailable(
            reason: "smartctl returned no recognized detailed health fields; the drive or bridge may not expose them"
        )
    }
    return .reported(
        SMARTMetrics(
            temperatureCelsius: temperature,
            mediaErrors: mediaErrors,
            unsafeShutdowns: unsafeShutdowns,
            powerOnHours: powerOnHours,
            percentageUsed: percentageUsed,
            source: smartDataSource(
                protocolName: document.device?.protocolName,
                hasNVMeHealthLog: document.nvmeHealth != nil
            ),
            collector: collector,
            collectorExitStatus: exitStatus
        )
    )
}

func expandedSMARTSummary(_ expandedSMART: ExpandedSMART) -> String {
    switch expandedSMART {
    case let .unavailable(reason):
        return "Detailed SMART unavailable — \(reason)"
    case let .reported(metrics):
        var values: [String] = []
        if let temperature = metrics.temperatureCelsius {
            values.append("Temperature \(temperature)°C")
        }
        if let mediaErrors = metrics.mediaErrors {
            values.append("Media errors \(mediaErrors)")
        }
        if let unsafeShutdowns = metrics.unsafeShutdowns {
            values.append("Unsafe shutdowns \(unsafeShutdowns)")
        }
        if let powerOnHours = metrics.powerOnHours {
            values.append("Power-on hours \(powerOnHours)")
        }
        if let percentageUsed = metrics.percentageUsed {
            values.append("Percentage used \(percentageUsed)%")
        }
        return "Detailed SMART [\(metrics.source.rawValue)]: \(values.joined(separator: " • "))"
    }
}

func expandedSMARTCaveat(_ expandedSMART: ExpandedSMART) -> String? {
    guard case let .reported(metrics) = expandedSMART else {
        return nil
    }
    let sourceCaveat: String
    switch metrics.source {
    case .nvme:
        sourceCaveat = "Controller-reported NVMe counters; USB or Thunderbolt bridge firmware may suppress, cache, or transform them."
    case .ata:
        sourceCaveat = "ATA attribute names and raw values are vendor-specific and are not directly comparable across drive models."
    case .scsi:
        sourceCaveat = "SCSI or bridge-reported health data may be incomplete or translated from vendor-specific counters."
    case .unknown:
        sourceCaveat = "Drive or bridge-reported health data has unknown vendor semantics and may be incomplete."
    }
    let statusCaveat = metrics.collectorExitStatus == 0
        ? ""
        : " The collector returned status \(metrics.collectorExitStatus); treat the values as partial and review the device separately."
    return "Vendor-data caveat: \(sourceCaveat) Collected by \(metrics.collector).\(statusCaveat)"
}

private func ataRawValue(names: [String], attributes: [SmartctlATAAttribute]) -> UInt64? {
    for name in names {
        if let value = attributes.first(where: { normalizedSMARTName($0.name) == name })?.raw.value {
            return value
        }
    }
    return nil
}

private func normalizedSMARTName(_ value: String) -> String {
    value.lowercased().filter { character in
        character.isLetter || character.isNumber
    }
}

private func intValue(_ value: UInt64?) -> Int? {
    guard let value else {
        return nil
    }
    return Int(exactly: value)
}

private func smartDataSource(protocolName: String?, hasNVMeHealthLog: Bool) -> SMARTDataSource {
    if hasNVMeHealthLog {
        return .nvme
    }
    let normalized = protocolName?.lowercased() ?? ""
    if normalized.contains("ata") {
        return .ata
    }
    if normalized.contains("scsi") {
        return .scsi
    }
    return .unknown
}

func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    return value
}

func isUserFacingAPFSVolume(_ volume: APFSVolumeRecord) -> Bool {
    let hiddenRoles: Set<String> = ["Preboot", "Recovery", "VM", "Update", "xART", "Hardware"]
    return hiddenRoles.isDisjoint(with: volume.roles)
}

func isVirtualUnlockerDisk(_ info: DiskInfoPropertyList) -> Bool {
    let content = info.content?.lowercased() ?? ""
    let names = [info.mediaName, info.registryName]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    return content == "cd_partition_scheme" && names.contains("virtual cd")
}

func flattenedPartitions(_ partitions: [DiskListPartition]) -> [DiskListPartition] {
    partitions.flatMap { partition in
        [partition] + flattenedPartitions(partition.partitions)
    }
}

func deviceIdentifier(_ candidate: String, isSameAsOrDescendantOf ancestor: String) -> Bool {
    candidate == ancestor || candidate.hasPrefix("\(ancestor)s")
}

func formattedByteCount(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .decimal)
}

func volumeMenuTitle(_ volume: ExternalVolume) -> String {
    let mountState = volume.mountPoint == nil ? "Not mounted" : "Mounted"
    let encryptionState = volume.isLocked ? "Locked" : (volume.isEncrypted ? "Encrypted" : "Not encrypted")
    return "\(volume.name) — /dev/\(volume.identifier) — \(volume.filesystem) — \(mountState) — \(encryptionState)"
}

func usbLinkSpeedBitsPerSecond(from output: String, productName: String) -> Int64? {
    guard !productName.isEmpty else {
        return nil
    }
    let escapedName = NSRegularExpression.escapedPattern(for: productName)
    let pattern = "(?s)\\+-o\\s+\(escapedName)@[^\\n]*<class IOUSBHostDevice.*?\\\"UsbLinkSpeed\\\"\\s*=\\s*([0-9]+)"
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    guard
        let match = expression.firstMatch(in: output, range: range),
        let speedRange = Range(match.range(at: 1), in: output)
    else {
        return nil
    }
    return Int64(output[speedRange])
}

func formattedLinkSpeed(_ bitsPerSecond: Int64) -> String {
    if bitsPerSecond >= 1_000_000_000 {
        let gigabits = Double(bitsPerSecond) / 1_000_000_000
        return String(format: "%.1f Gb/s", gigabits)
    }
    if bitsPerSecond >= 1_000_000 {
        let megabits = Double(bitsPerSecond) / 1_000_000
        return String(format: "%.0f Mb/s", megabits)
    }
    return "\(bitsPerSecond) b/s"
}

func guidedFailureExplanation(exitStatus: Int32, output: String, volume: ExternalVolume) -> String {
    let normalized = output.lowercased()
    let prefix = "GUIDED EXPLANATION [exit status \(exitStatus)]: "

    if volume.isLocked || normalized.contains("locked") || normalized.contains("encrypted") {
        return prefix + "The volume is encrypted and locked. Unlock it in Finder or Disk Utility, then refresh. This app does not request or store credentials."
    }
    if normalized.contains("resource busy") || normalized.contains("in use") {
        return prefix + "macOS reports the volume is busy. Close files and applications using it, then retry. Do not force-eject a busy volume."
    }
    if normalized.contains("no such file") || normalized.contains("could not find") || normalized.contains("disappeared") {
        return prefix + "The selected disk identifier is no longer present. Reconnect the device or press Refresh because disk numbers can change."
    }
    if normalized.contains("not recognized") || normalized.contains("unsupported") || normalized.contains("no mountable file systems") {
        return prefix + "macOS does not recognize a mountable filesystem on this volume. Preserve the device and inspect it before using any erase or repair operation."
    }
    if normalized.contains("fsck") || normalized.contains("file system check") {
        return prefix + "A filesystem check is active or required. Wait for an active check to finish; this app deliberately does not run a repair."
    }
    if normalized.contains("permission denied") || normalized.contains("not permitted") || normalized.contains("authorization") {
        return prefix + "Disk Arbitration denied the operation. Try the same volume in Finder or Disk Utility so macOS can present its own authorization UI."
    }
    if normalized.contains("read-only") || normalized.contains("write protected") {
        return prefix + "The media or filesystem is read-only. This is compatible with read-only access, but writable mounting is unavailable."
    }
    if exitStatus == 0 {
        return prefix + "The command succeeded, but the requested mount state was not verified. Review the current diskutil information and recent Disk Arbitration errors below."
    }
    return prefix + "No specific known signature matched. The exact diskutil output above and recent Disk Arbitration errors below are the authoritative evidence."
}

func privacyRedactedReport(_ report: String, userName: String) -> String {
    var redacted = report.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/[USER]")
    let replacements: [(String, String)] = [
        (#"(?i)(USB Serial Number|Serial Number|kUSBSerialNumberString)(\"?\s*[:=]\s*\"?)[A-Za-z0-9._-]+"#, "$1$2[REDACTED]"),
        (#"(?i)(sessionID\"?\s*=\s*)[0-9]+"#, "$1[REDACTED]"),
        (#"(?i)(UID|Domain UUID|Disk UUID|Volume UUID)(:\s*)[^\s]+"#, "$1$2[REDACTED]"),
        (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "[UUID]")
    ]

    for (pattern, replacement) in replacements {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            continue
        }
        let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
        redacted = expression.stringByReplacingMatches(
            in: redacted,
            range: range,
            withTemplate: replacement
        )
    }
    return "Privacy redaction: enabled\n\n\(redacted)"
}

func runSelfTests() -> Bool {
    let diskListXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>AllDisksAndPartitions</key><array><dict>
    <key>DeviceIdentifier</key><string>disk4</string><key>Size</key><integer>2000</integer>
    <key>Partitions</key><array><dict><key>DeviceIdentifier</key><string>disk4s1</string><key>Size</key><integer>1000</integer></dict></array>
    </dict></array></dict></plist>
    """
    guard
        let decoded = try? decodePropertyList(
            DiskListPropertyList.self,
            output: diskListXML,
            command: "self-test"
        ),
        decoded.disks.first?.identifier == "disk4"
    else {
        return false
    }

    let unlockerInfoXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>DeviceIdentifier</key><string>disk3</string>
    <key>Content</key><string>CD_partition_scheme</string>
    <key>MediaName</key><string>Virtual CD 55AE</string>
    </dict></plist>
    """
    guard
        let unlockerInfo = try? decodePropertyList(
            DiskInfoPropertyList.self,
            output: unlockerInfoXML,
            command: "self-test"
        ),
        isVirtualUnlockerDisk(unlockerInfo)
    else {
        return false
    }

    let nestedDiskListXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>AllDisksAndPartitions</key><array><dict>
    <key>DeviceIdentifier</key><string>disk3</string><key>Size</key><integer>36000000</integer>
    <key>Partitions</key><array><dict>
    <key>DeviceIdentifier</key><string>disk3s0</string><key>Size</key><integer>35000000</integer>
    <key>Partitions</key><array><dict>
    <key>DeviceIdentifier</key><string>disk3s0s2</string><key>Size</key><integer>2500000</integer>
    </dict></array></dict></array>
    </dict></array></dict></plist>
    """
    guard
        let nestedDiskList = try? decodePropertyList(
            DiskListPropertyList.self,
            output: nestedDiskListXML,
            command: "self-test"
        ),
        flattenedPartitions(nestedDiskList.disks[0].partitions).map(\.identifier) == ["disk3s0", "disk3s0s2"]
    else {
        return false
    }

    let testVolume = ExternalVolume(
        identifier: "disk4s1",
        wholeDiskIdentifier: "disk4",
        name: "Extreme SSD",
        filesystem: "ExFAT",
        mountPoint: "/Volumes/Extreme SSD",
        isEncrypted: false,
        isLocked: false,
        isWritable: true,
        role: nil,
        size: 2_000_000_000_000
    )
    let unmountedVolume = ExternalVolume(
        identifier: "disk6s1",
        wholeDiskIdentifier: "disk6",
        name: "Unmounted Test",
        filesystem: "APFS",
        mountPoint: nil,
        isEncrypted: false,
        isLocked: false,
        isWritable: false,
        role: nil,
        size: 1_000_000
    )
    let lockedVolume = ExternalVolume(
        identifier: "disk7s1",
        wholeDiskIdentifier: "disk7",
        name: "Locked Test",
        filesystem: "APFS",
        mountPoint: nil,
        isEncrypted: true,
        isLocked: true,
        isWritable: false,
        role: nil,
        size: 1_000_000
    )
    let nvmeSMARTJSON = """
    {
      "device": { "protocol": "NVMe" },
      "temperature": { "current": 41 },
      "power_on_time": { "hours": 1234 },
      "nvme_smart_health_information_log": {
        "temperature": 41,
        "percentage_used": 7,
        "power_on_hours": 1234,
        "unsafe_shutdowns": 3,
        "media_errors": 2
      }
    }
    """
    let ataSMARTJSON = """
    {
      "device": { "protocol": "ATA" },
      "temperature": { "current": 35 },
      "power_on_time": { "hours": 567 },
      "ata_smart_attributes": {
        "table": [
          { "name": "Reported_Uncorrect", "raw": { "value": 4 } },
          { "name": "Unsafe_Shutdown_Count", "raw": { "value": 6 } },
          { "name": "Percentage_Used", "raw": { "value": 8 } }
        ]
      }
    }
    """
    let nvmeExpandedSMART = try? decodeExpandedSMART(
        output: nvmeSMARTJSON,
        command: "smartctl self-test",
        collector: "/opt/homebrew/sbin/smartctl",
        exitStatus: 0
    )
    let ataExpandedSMART = try? decodeExpandedSMART(
        output: ataSMARTJSON,
        command: "smartctl self-test",
        collector: "/opt/homebrew/sbin/smartctl",
        exitStatus: 4
    )
    let unavailableExpandedSMART = try? decodeExpandedSMART(
        output: "{\"device\":{\"protocol\":\"NVMe\"}}",
        command: "smartctl self-test",
        collector: "/opt/homebrew/sbin/smartctl",
        exitStatus: 0
    )
    let nvmeMetrics: SMARTMetrics?
    if case let .some(.reported(metrics)) = nvmeExpandedSMART {
        nvmeMetrics = metrics
    } else {
        nvmeMetrics = nil
    }
    let ataMetrics: SMARTMetrics?
    if case let .some(.reported(metrics)) = ataExpandedSMART {
        ataMetrics = metrics
    } else {
        ataMetrics = nil
    }
    let testUnlocker = VirtualUnlocker(
        wholeDiskIdentifier: "disk3",
        volumeIdentifier: "disk3s0s2",
        name: "SanDisk Unlocker",
        mountPoint: "/Volumes/SanDisk Unlocker",
        deviceTreePath: "IODeviceTree:/usb/storage"
    )
    let unlockSnapshot = DiskSnapshot(
        disks: [
            ExternalDisk(
                identifier: "disk4",
                name: "Extreme 55AE",
                deviceTreePath: "IODeviceTree:/usb/storage",
                busProtocol: "USB",
                smartStatus: "Verified",
                expandedSMART: nvmeExpandedSMART ?? .unavailable(reason: "self-test decode failed"),
                size: 2_000_000_000_000,
                volumes: [testVolume]
            )
        ],
        unlockers: [testUnlocker],
        scanFailures: [
            DiskScanFailure(
                diskIdentifier: "disk5",
                errorDescription: "Command failed with exit status 1: /usr/sbin/diskutil info -plist /dev/disk5"
            )
        ]
    )
    let partialSnapshot = try? externalDiskSnapshot(
        entries: [nestedDiskList.disks[0], decoded.disks[0]]
    ) { entry in
        if entry.identifier == "disk3" {
            throw TroubleshooterError.commandFailed(
                command: "/usr/sbin/diskutil info -plist /dev/disk3",
                exitStatus: 1,
                output: "I/O error while reading disk3"
            )
        }
        return .disk(unlockSnapshot.disks[0])
    }
    guard
        unlockSnapshot.dataVolume(matching: testUnlocker) == testVolume,
        unlockSnapshot.removingDevice(identifier: "disk4s1").volumes.isEmpty,
        unlockSnapshot.removingDevice(identifier: "disk4").disks.isEmpty,
        unlockSnapshot.removingDevice(identifier: "disk3s0").unlockers.isEmpty,
        unlockSnapshot.removingDevice(identifier: "disk5").scanFailures.isEmpty,
        unlockSnapshot.volumes == [testVolume],
        unlockSnapshot.scanFailures.first?.diskIdentifier == "disk5",
        partialSnapshot?.volumes == [testVolume],
        partialSnapshot?.scanFailures.first?.diskIdentifier == "disk3",
        partialSnapshot?.scanFailures.first?.errorDescription.contains("exit status 1") == true,
        partialSnapshot?.scanFailures.first?.errorDescription.contains("I/O error while reading disk3") == true,
        volumeActionAvailability(for: nil) == VolumeActionAvailability(
            inspect: false,
            mountReadOnly: false,
            mountNormally: false,
            unmountVolume: false,
            safeEjectDisk: false
        ),
        volumeActionAvailability(for: testVolume) == VolumeActionAvailability(
            inspect: true,
            mountReadOnly: true,
            mountNormally: false,
            unmountVolume: true,
            safeEjectDisk: true
        ),
        volumeActionAvailability(for: unmountedVolume) == VolumeActionAvailability(
            inspect: true,
            mountReadOnly: true,
            mountNormally: true,
            unmountVolume: false,
            safeEjectDisk: true
        ),
        volumeActionAvailability(for: lockedVolume) == VolumeActionAvailability(
            inspect: true,
            mountReadOnly: false,
            mountNormally: false,
            unmountVolume: false,
            safeEjectDisk: true
        ),
        nvmeMetrics?.temperatureCelsius == 41,
        nvmeMetrics?.mediaErrors == 2,
        nvmeMetrics?.unsafeShutdowns == 3,
        nvmeMetrics?.powerOnHours == 1234,
        nvmeMetrics?.percentageUsed == 7,
        nvmeMetrics?.source == .nvme,
        ataMetrics?.temperatureCelsius == 35,
        ataMetrics?.mediaErrors == 4,
        ataMetrics?.unsafeShutdowns == 6,
        ataMetrics?.powerOnHours == 567,
        ataMetrics?.percentageUsed == 8,
        ataMetrics?.source == .ata,
        expandedSMARTSummary(nvmeExpandedSMART ?? .unavailable(reason: "missing")).contains("Temperature 41°C"),
        expandedSMARTCaveat(ataExpandedSMART ?? .unavailable(reason: "missing"))?.contains("vendor-specific") == true,
        expandedSMARTCaveat(ataExpandedSMART ?? .unavailable(reason: "missing"))?.contains("status 4") == true,
        expandedSMARTSummary(unavailableExpandedSMART ?? .reported(
            SMARTMetrics(
                temperatureCelsius: 0,
                mediaErrors: nil,
                unsafeShutdowns: nil,
                powerOnHours: nil,
                percentageUsed: nil,
                source: .unknown,
                collector: "self-test",
                collectorExitStatus: 0
            )
        )).contains("unavailable"),
        deviceIdentifier("disk4s1", isSameAsOrDescendantOf: "disk4"),
        !deviceIdentifier("disk40s1", isSameAsOrDescendantOf: "disk4"),
        UnlockTransitionPhase.retry(attempt: 2, limit: 5).message.contains("retry 2 of 5"),
        UnlockTransitionPhase.ready(volumeName: "Extreme SSD").message.hasSuffix("Extreme SSD ready")
    else {
        return false
    }

    do {
        _ = try externalDiskSnapshot(entries: [decoded.disks[0]]) { _ in
            throw TroubleshooterError.cancelled
        }
        return false
    } catch TroubleshooterError.cancelled {
    } catch {
        return false
    }

    let timeoutRunner = CommandRunner()
    do {
        _ = try timeoutRunner.run(
            executable: "/bin/sleep",
            arguments: ["1"],
            timeoutSeconds: 0.05
        ) { _ in }
        return false
    } catch let error as TroubleshooterError {
        guard case .commandTimedOut = error else {
            return false
        }
    } catch {
        return false
    }

    let ioreg = #"+-o Drive@1 <class IOUSBHostDevice, id 1> { "UsbLinkSpeed" = 10000000000 }"#
    guard usbLinkSpeedBitsPerSecond(from: ioreg, productName: "Drive") == 10_000_000_000 else {
        return false
    }

    let report = "USB Serial Number: ABC123\nVolume UUID: 12345678-1234-1234-1234-123456789ABC"
    let redacted = privacyRedactedReport(report, userName: "tester")
    return !redacted.contains("ABC123") && !redacted.contains("12345678-1234")
}
