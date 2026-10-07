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
    node.usb?.productName ?? node.className
}

func physicalConnectionSummary(_ transport: PhysicalTransport) -> String {
    switch transport {
    case let .unavailable(reason):
        return "Physical connection unavailable: \(reason)"
    case let .observed(path):
        let visibleNodes = path.nodes.filter {
            [.controller, .port, .hub, .usbDevice, .thunderbolt].contains($0.role)
        }
        let chain = (["Mac"] + visibleNodes.map(transportNodeLabel) + ["/dev/\(path.diskIdentifier)"]).joined(separator: " → ")
        let speed = path.storageUSBNode?.usb?.negotiatedBitsPerSecond.map(formattedLinkSpeed) ?? "unavailable"
        return "Physical connection: \(chain)\nSelected storage USB link: \(speed). Use Inspect for evidence and transport coverage."
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
        "Physical-store evidence: \(physicalStoreIdentifiers.joined(separator: ", "))"
    ]
    switch transport {
    case let .unavailable(reason):
        lines += [
            "Correlation: unresolved",
            "Transport coverage: unavailable — \(reason)",
            "No device association or connection cause was inferred."
        ]
    case let .observed(path):
        lines += [
            "Collected: \(ISO8601DateFormatter().string(from: path.collectedAt))",
            "BSD disk: /dev/\(path.diskIdentifier) (current identifier, not a persistent identity)",
            "diskutil bus protocol: \(path.busProtocol)",
            "Correlation: exact current IOMedia BSD Name and Whole=true; unique IOService parent ancestry",
            "diskutil DeviceTreePath witness: \(path.deviceTreePathVerified ? "verified in the same ancestry" : "unavailable")",
            "Physical path (Mac → block media):"
        ]
        if let endpoint = path.storageUSBNode {
            lines.insert("USB storage device/bridge: \(transportNodeLabel(endpoint)) (enumerated identity; internal chipset unverified)", at: lines.count - 1)
        }
        for node in path.nodes {
            lines.append("  \(node.role.rawValue): \(transportNodeLabel(node)) [\(node.className), registryID=0x\(String(node.registryEntryID, radix: 16))]")
            if let usb = node.usb {
                let vendor = usb.vendorID.map { String(format: "0x%04x", $0) } ?? "unavailable"
                let product = usb.productID.map { String(format: "0x%04x", $0) } ?? "unavailable"
                let location = usb.locationID.map { String(format: "0x%08x", $0) } ?? "unavailable"
                lines.append("    USB identity: vendor=\(usb.vendorName ?? "unavailable"), VID=\(vendor), PID=\(product), locationID=\(location)")
                lines.append("    Negotiated link (UsbLinkSpeed): \(usb.negotiatedBitsPerSecond.map(formattedLinkSpeed) ?? "unavailable")")
                let revision = usb.descriptorVersion.flatMap(usbDescriptorRevision) ?? "unavailable"
                lines.append("    Device descriptor bcdUSB: \(revision) (protocol revision; does not establish maximum speed)")
                if usb.tunneledThroughUSB4 == true {
                    lines.append("    UsbTunnel: true — USB4 tunnel reported; dock identity and tunnel rate are not established")
                }
            }
            if node.role == .storageInterface {
                let protocolLabel: String
                switch node.storageInterfaceProtocol {
                case 0x50: protocolLabel = "Bulk-Only Transport (0x50)"
                case 0x62: protocolLabel = "USB Attached SCSI (0x62)"
                case let code?: protocolLabel = String(format: "reported interface protocol 0x%02x", code)
                case nil: protocolLabel = "interface protocol unavailable"
                }
                lines.append("    bInterfaceClass=0x08; \(protocolLabel)")
            }
        }
        lines += transportCoverage(path)
        lines += transportExplanations(path: path, smartStatus: smartStatus)
    }
    return lines.joined(separator: "\n") + "\n\n"
}

func transportCoverage(_ path: PhysicalTransportPath) -> [String] {
    let hubCount = path.nodes.filter { $0.role == .hub }.count
    let controllerPresent = path.nodes.contains { $0.role == .controller }
    let usbPresent = path.nodes.contains { $0.usb != nil }
    let endpoint = path.storageUSBNode
    return [
        "TRANSPORT COVERAGE",
        "  IOMedia / BSD correlation: reported",
        "  IOService ancestry: reported (\(path.nodes.count) nodes)",
        "  USB host controller: \(controllerPresent ? "reported" : "unavailable in this ancestry")",
        "  USB hubs: \(usbPresent ? "\(hubCount) observed ancestor(s); an unenumerated dock or adapter cannot be excluded" : "unsupported for this non-USB path")",
        "  USB storage device/bridge identity: \(endpoint != nil ? "reported from the device above the mass-storage interface" : "unavailable; no proven USB mass-storage endpoint in this ancestry")",
        "  Internal bridge chipset / SATA or NVMe mapping: unavailable; VID/PID and product strings do not prove chip identity",
        "  Selected endpoint negotiated rate: \(endpoint?.usb?.negotiatedBitsPerSecond != nil ? "reported by UsbLinkSpeed" : (usbPresent ? "unavailable; UsbLinkSpeed absent at the storage endpoint" : "unsupported for this non-USB path"))",
        "  Advertised maximum rate: unavailable; descriptor revision is not a speed claim",
        "  Thunderbolt / USB4 link-rate enrichment: unsupported; any observed services remain in the path",
        "  Chassis port label, cable capability and available power: unavailable",
        "  USB property stability: UsbLinkSpeed, UsbTunnel and locationID availability varies by macOS and hardware"
    ]
}

func transportExplanations(path: PhysicalTransportPath, smartStatus: String) -> [String] {
    var lines = ["BOUNDED TRANSPORT EXPLANATIONS"]
    if let rate = path.storageUSBNode?.usb?.negotiatedBitsPerSecond {
        lines.append("  The selected endpoint reports \(formattedLinkSpeed(rate)) signaling, not measured storage throughput.")
        if rate <= 480_000_000 {
            lines.append("  This low signaling rate can constrain transfers. Port, hub, adapter, device or cable negotiation could contribute; these observations do not identify which component is responsible.")
        }
    }
    if path.nodes.contains(where: { $0.role == .hub }) {
        lines.append("  An intermediate USB hub is observed. Concurrent traffic could share upstream bandwidth; competing traffic and a resulting bottleneck were not measured.")
    }
    if path.storageUSBNode != nil, smartStatus.lowercased().contains("not supported") {
        lines.append("  diskutil reports SMART Not Supported on this USB path. Passthrough may be unavailable, but neither bridge behavior nor drive health is established.")
    }
    lines.append("  This topology does not establish the cause of a mount failure or disconnect, cable quality, available power, bridge reliability or drive health.")
    return lines
}
