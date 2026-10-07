import Foundation

enum TransportNodeRole: String, Hashable, Sendable {
    case controller = "Host controller"
    case port = "USB port service"
    case hub = "USB hub"
    case usbDevice = "USB device"
    case storageInterface = "USB mass-storage interface"
    case storageDriver = "Storage driver"
    case thunderbolt = "Thunderbolt service"
    case media = "Block media"
    case other = "Registry ancestor"
}

struct USBTransportProperties: Hashable, Sendable {
    let productName: String?
    let vendorName: String?
    let vendorID: UInt16?
    let productID: UInt16?
    let locationID: UInt32?
    let descriptorVersion: UInt16?
    let negotiatedBitsPerSecond: Int64?
    let tunneledThroughUSB4: Bool?
}

struct TransportNode: Hashable, Sendable {
    let registryEntryID: UInt64
    let className: String
    let role: TransportNodeRole
    let usb: USBTransportProperties?
    let storageInterfaceProtocol: UInt8?
}

struct PhysicalTransportPath: Hashable, Sendable {
    let diskIdentifier: String
    let busProtocol: String
    let collectedAt: Date
    /// Ordered from the registry root to the exact whole-disk IOMedia service.
    let nodes: [TransportNode]
    let deviceTreePathVerified: Bool

    var storageUSBNode: TransportNode? {
        guard
            let deviceIndex = nodes.lastIndex(where: { $0.role == .usbDevice }),
            nodes.dropFirst(deviceIndex + 1).contains(where: { $0.role == .storageInterface })
        else {
            return nil
        }
        return nodes[deviceIndex]
    }

    var mediaRegistryEntryID: UInt64? {
        nodes.last?.role == .media ? nodes.last?.registryEntryID : nil
    }
}

enum PhysicalTransport: Hashable, Sendable {
    case observed(PhysicalTransportPath)
    case unavailable(reason: String)
}

/// Identity remains available even when optional transport properties or ancestry collection fail.
enum PhysicalMediaIdentity: Hashable, Sendable {
    case observed(registryEntryID: UInt64)
    case unavailable(reason: String)
}

/// Accepts only BSD whole disks or their partitions; names and prefixes never establish association.
func wholeDiskIdentifier(forPhysicalStore identifier: String) -> String? {
    guard identifier.count <= 64 else {
        return nil
    }
    guard identifier.hasPrefix("disk") else {
        return nil
    }
    let components = identifier.dropFirst(4).split(separator: "s", omittingEmptySubsequences: false)
    guard
        let diskNumber = components.first,
        !diskNumber.isEmpty,
        diskNumber.allSatisfy({ $0 >= "0" && $0 <= "9" }),
        components.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } })
    else {
        return nil
    }
    return "disk\(diskNumber)"
}

/// APFS volumes with multiple physical stores have no single selected-disk transport path.
func selectedPhysicalTransport(volume: ExternalVolume, disk: ExternalDisk) -> PhysicalTransport {
    guard volume.physicalStoreIdentifiers.count == 1 else {
        return .unavailable(reason: "The selected volume has \(volume.physicalStoreIdentifiers.count) physical stores. A single physical path cannot be attributed to it; inspect each backing disk separately.")
    }
    guard
        wholeDiskIdentifier(forPhysicalStore: volume.physicalStoreIdentifiers[0]) == disk.identifier,
        volume.wholeDiskIdentifier == disk.identifier
    else {
        return .unavailable(reason: "The selected volume's physical-store evidence does not match /dev/\(disk.identifier). Refresh the storage inventory before inspecting it.")
    }
    if case let .observed(path) = disk.physicalTransport {
        guard case let .observed(identity) = disk.mediaIdentity,
              path.diskIdentifier == disk.identifier,
              path.mediaRegistryEntryID == identity else {
            return .unavailable(reason: "The transport snapshot does not match the selected disk's captured media identity. Refresh the storage inventory.")
        }
    }
    return disk.physicalTransport
}

func usbDescriptorRevision(_ version: UInt16) -> String? {
    let digits = [version >> 12, (version >> 8) & 15, (version >> 4) & 15, version & 15]
    guard digits.allSatisfy({ $0 <= 9 }) else {
        return nil
    }
    return "\(digits[0] * 10 + digits[1]).\(digits[2])\(digits[3])"
}

func transportNodeLabel(_ node: TransportNode) -> String {
    switch node.role {
    case .controller:
        return "USB controller"
    case .port:
        return "USB port"
    case .thunderbolt:
        return "Thunderbolt connection"
    case .hub, .usbDevice:
        guard let product = node.usb?.productName else {
            return node.role == .hub ? "USB hub (name unavailable)" : "USB device (name unavailable)"
        }
        let name: String
        if let vendor = node.usb?.vendorName, !product.localizedCaseInsensitiveContains(vendor) {
            name = "\(vendor) \(product)"
        } else {
            name = product
        }
        return node.role == .hub ? "USB hub (\(name))" : name
    case .storageInterface, .storageDriver, .media, .other:
        return node.role.rawValue
    }
}

/// Driver and platform services establish ancestry internally but are not physical connection steps.
func physicalConnectionPath(_ path: PhysicalTransportPath) -> String {
    let visibleNodes = path.nodes.filter {
        [.controller, .port, .hub, .usbDevice, .thunderbolt].contains($0.role)
    }
    return (["Mac"] + visibleNodes.map(transportNodeLabel) + ["/dev/\(path.diskIdentifier)"]).joined(separator: " → ")
}

func negotiatedConnectionSpeedSummary(_ path: PhysicalTransportPath) -> String {
    if let rate = path.storageUSBNode?.usb?.negotiatedBitsPerSecond {
        return "Negotiated USB speed: \(formattedLinkSpeed(rate)) (link rate, not measured storage throughput)"
    }
    if path.nodes.contains(where: { $0.usb != nil }) || path.busProtocol.caseInsensitiveCompare("USB") == .orderedSame {
        return "Negotiated USB speed: unavailable — macOS did not report a rate for the storage device."
    }
    return "Connection speed: unavailable — only USB link rates are supported."
}

func physicalConnectionSummary(_ transport: PhysicalTransport) -> String {
    switch transport {
    case let .unavailable(reason):
        return "Physical connection unavailable: \(reason)"
    case let .observed(path):
        return "Physical connection: \(physicalConnectionPath(path))\n\(negotiatedConnectionSpeedSummary(path))"
    }
}

/// Reports only the selected storage ancestry and allowlisted properties, never a USB inventory.
func physicalTransportReport(
    transport: PhysicalTransport,
    selectedIdentifier: String,
    physicalStoreIdentifiers: [String],
    smartStatus: String
) -> String {
    var lines = [
        "=== PHYSICAL CONNECTION ===",
        "Selected storage: /dev/\(selectedIdentifier)",
        "Backing storage: \(physicalStoreIdentifiers.isEmpty ? "unresolved" : physicalStoreIdentifiers.map { "/dev/\($0)" }.joined(separator: ", "))"
    ]
    switch transport {
    case let .unavailable(reason):
        lines += [
            "Physical connection unavailable: \(reason)",
            "Coverage: no verified physical connection is available; no connection cause was inferred."
        ]
    case let .observed(path):
        lines += [
            "Collected: \(ISO8601DateFormatter().string(from: path.collectedAt))",
            "Connection type: \(path.busProtocol)",
            "Physical path: \(physicalConnectionPath(path))",
            negotiatedConnectionSpeedSummary(path)
        ]
        if path.storageUSBNode != nil {
            let protocolLabel: String
            switch path.nodes.last(where: { $0.role == .storageInterface })?.storageInterfaceProtocol {
            case 0x50: protocolLabel = "USB Bulk-Only Transport"
            case 0x62: protocolLabel = "USB Attached SCSI (UAS)"
            case let code?: protocolLabel = String(format: "unrecognized USB interface protocol 0x%02x", code)
            case nil: protocolLabel = "unavailable — macOS did not report the USB storage protocol"
            }
            lines.append("Storage protocol: \(protocolLabel)")
        }
        for hub in path.nodes.filter({ $0.role == .hub }) {
            let speed = hub.usb?.negotiatedBitsPerSecond.map(formattedLinkSpeed) ?? "unavailable"
            lines.append("Hub link — \(transportNodeLabel(hub)): \(speed)")
        }
        if path.nodes.contains(where: { $0.usb?.tunneledThroughUSB4 == true }) {
            lines.append("USB4 tunnel: reported on this path; tunnel speed and dock identity are unavailable.")
        }
        let additionalMatch = path.deviceTreePathVerified ? "; diskutil's physical path agrees" : ""
        lines.append("Disk match: current macOS storage identity and ancestry verified\(additionalMatch). Disk numbers can change after reconnection.")
        lines += transportCoverage(path)
        lines += transportExplanations(path: path, smartStatus: smartStatus)
    }
    return lines.joined(separator: "\n") + "\n\n"
}

func transportCoverage(_ path: PhysicalTransportPath) -> [String] {
    let hubCount = path.nodes.filter { $0.role == .hub }.count
    let usbPresent = path.nodes.contains { $0.usb != nil } || path.busProtocol.caseInsensitiveCompare("USB") == .orderedSame
    var lines: [String] = []
    if usbPresent {
        lines.append(hubCount == 0
            ? "USB hubs: none reported on this path; unreported docks or adapters remain unknown."
            : "USB hubs: \(hubCount) reported on this path.")
        if !path.nodes.contains(where: { $0.role == .controller }) {
            lines.append("Coverage: the USB controller was not identified in this path.")
        }
        if path.storageUSBNode == nil {
            lines.append("Coverage: the USB storage device/bridge was not identified; its speed and storage protocol are unavailable.")
        }
    } else {
        lines.append("Coverage: USB device details are unsupported for this non-USB path.")
    }
    if !path.deviceTreePathVerified {
        lines.append("Coverage: the additional macOS physical-path check is unavailable.")
    }
    lines += [
        "Unavailable: advertised maximum speed, internal bridge chipset, chassis port label, cable capability and available power.",
        "Unsupported: Thunderbolt/USB4 link speeds."
    ]
    return lines
}

func transportExplanations(path: PhysicalTransportPath, smartStatus: String) -> [String] {
    var lines: [String] = []
    if let rate = path.storageUSBNode?.usb?.negotiatedBitsPerSecond, rate <= 480_000_000 {
        lines.append("Possible effect: the \(formattedLinkSpeed(rate)) USB link can limit transfers; the limiting component has not been identified.")
    }
    if path.nodes.contains(where: { $0.role == .hub }) {
        lines.append("Possible effect: devices on the reported USB hub may share bandwidth; competing traffic was not measured.")
    }
    if path.storageUSBNode != nil, smartStatus.lowercased().contains("not supported") {
        lines.append("Health limitation: SMART is not supported on this USB path. Limited passthrough is possible; a drive fault is not established.")
    }
    lines.append("Interpretation: these connection observations do not establish the cause of a mount failure or disconnect, or prove bridge reliability.")
    return lines
}
