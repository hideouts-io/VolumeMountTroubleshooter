import Foundation
import IOKit

enum TransportScanError: LocalizedError {
    case registry(operation: String, status: kern_return_t)
    case invalidObservation(reason: String)

    var errorDescription: String? {
        switch self {
        case let .registry(operation, status):
            return "Storage transport collection failed during \(operation) (IOKit status \(String(format: "0x%08x", UInt32(bitPattern: status)))). Refresh after the device settles."
        case let .invalidObservation(reason):
            return "Storage transport collection could not establish a unique current path: \(reason). Refresh the selected storage device."
        }
    }
}

/// Read-only IOKit boundary. No properties, USB interfaces or device settings are changed.
/// PlugSense's probe APIs were reviewed as a reference; this implementation shares no source.
/// Reference: https://github.com/yasir24s/PlugSense/blob/eb3b4e73927c02dfa65abb66f6a6038fb9b90303/Sources/PlugSenseKit/Probe.swift
final class TransportScanner {
    private let runner: CommandRunner

    init(runner: CommandRunner) {
        self.runner = runner
    }

    /// Captures exact current block-media identity independently of optional topology observations.
    func mediaRegistryEntryID(diskIdentifier: String) throws -> UInt64 {
        guard wholeDiskIdentifier(forPhysicalStore: diskIdentifier) == diskIdentifier else {
            throw TransportScanError.invalidObservation(reason: "a validated whole-disk BSD identifier is required")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        try checkCollectionDeadline(deadline)
        let media = try matchingMedia(diskIdentifier)
        defer { IOObjectRelease(media) }
        let identifier = try entryID(media)
        try checkCollectionDeadline(deadline)
        return identifier
    }

    func scan(
        diskIdentifier: String,
        busProtocol: String,
        expectedDeviceTreePath: String?
    ) throws -> PhysicalTransportPath {
        guard wholeDiskIdentifier(forPhysicalStore: diskIdentifier) == diskIdentifier else {
            throw TransportScanError.invalidObservation(reason: "a validated whole-disk BSD identifier is required")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        try checkCollectionDeadline(deadline)
        let media = try matchingMedia(diskIdentifier)
        defer { IOObjectRelease(media) }
        let mediaID = try entryID(media)
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else {
            throw TransportScanError.invalidObservation(reason: "the IOService registry root is unavailable")
        }
        defer { IOObjectRelease(root) }
        let rootID = try entryID(root)

        var nodes: [TransportNode] = []
        var seenIDs: Set<UInt64> = []
        try IOObjectRetainChecked(media)
        var current = media
        defer { if current != 0 { IOObjectRelease(current) } }
        while current != 0 {
            try checkCollectionDeadline(deadline)
            let node = try readNode(current)
            guard nodes.count < 64, seenIDs.insert(node.registryEntryID).inserted else {
                throw TransportScanError.invalidObservation(reason: "ancestry exceeded 64 entries or contained a cycle")
            }
            nodes.append(node)
            if node.registryEntryID == rootID {
                break
            }
            let parent = try uniqueParent(current)
            IOObjectRelease(current)
            current = parent
        }

        let orderedNodes = Array(nodes.reversed())
        var pathVerified = false
        if let expectedDeviceTreePath {
            guard expectedDeviceTreePath.hasPrefix("IODeviceTree:"), expectedDeviceTreePath.utf8.count < 4096 else {
                throw TransportScanError.invalidObservation(reason: "diskutil DeviceTreePath is invalid")
            }
            let witness = IORegistryEntryFromPath(kIOMainPortDefault, expectedDeviceTreePath)
            guard witness != 0 else {
                throw TransportScanError.invalidObservation(reason: "diskutil DeviceTreePath no longer resolves")
            }
            defer { IOObjectRelease(witness) }
            pathVerified = seenIDs.contains(try entryID(witness))
            guard pathVerified else {
                throw TransportScanError.invalidObservation(reason: "diskutil DeviceTreePath is outside the matched media's ancestry")
            }
        }
        try checkCollectionDeadline(deadline)
        let currentMedia = try matchingMedia(diskIdentifier)
        defer { IOObjectRelease(currentMedia) }
        guard try entryID(currentMedia) == mediaID else {
            throw TransportScanError.invalidObservation(reason: "the BSD disk was replaced while collecting its path")
        }
        return PhysicalTransportPath(
            diskIdentifier: diskIdentifier,
            busProtocol: busProtocol,
            collectedAt: Date(),
            nodes: orderedNodes,
            deviceTreePathVerified: pathVerified
        )
    }

    private func matchingMedia(_ diskIdentifier: String) throws -> io_registry_entry_t {
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, diskIdentifier) else {
            throw TransportScanError.invalidObservation(reason: "IOBSDNameMatching could not create the disk lookup")
        }
        var iterator: io_iterator_t = 0
        try checkStatus(IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator), operation: "matching /dev/\(diskIdentifier)")
        defer { IOObjectRelease(iterator) }
        let media = IOIteratorNext(iterator)
        guard media != 0 else {
            throw TransportScanError.invalidObservation(reason: "no current IOMedia publishes /dev/\(diskIdentifier)")
        }
        let additional = IOIteratorNext(iterator)
        if additional != 0 {
            IOObjectRelease(additional)
            IOObjectRelease(media)
            throw TransportScanError.invalidObservation(reason: "more than one service publishes the selected BSD name")
        }
        do {
            guard
                IOIteratorIsValid(iterator) != 0,
                IOObjectConformsTo(media, "IOMedia") != 0,
                try stringProperty(media, key: "BSD Name") == diskIdentifier,
                try booleanProperty(media, key: "Whole") == true
            else {
                throw TransportScanError.invalidObservation(reason: "the BSD match is not a current whole-disk IOMedia")
            }
            return media
        } catch {
            IOObjectRelease(media)
            throw error
        }
    }

    private func uniqueParent(_ entry: io_registry_entry_t) throws -> io_registry_entry_t {
        var iterator: io_iterator_t = 0
        try checkStatus(IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator), operation: "reading selected-media parents")
        defer { IOObjectRelease(iterator) }
        let parent = IOIteratorNext(iterator)
        let additional = IOIteratorNext(iterator)
        guard parent != 0, additional == 0, IOIteratorIsValid(iterator) != 0 else {
            if parent != 0 { IOObjectRelease(parent) }
            if additional != 0 { IOObjectRelease(additional) }
            throw TransportScanError.invalidObservation(reason: "an ancestor disappeared or has multiple IOService parents")
        }
        return parent
    }

    private func readNode(_ entry: io_registry_entry_t) throws -> TransportNode {
        guard let classValue = IOObjectCopyClass(entry)?.takeRetainedValue() else {
            throw TransportScanError.invalidObservation(reason: "an ancestor's registry class is unavailable")
        }
        let className = classValue as String
        let role: TransportNodeRole
        var usb: USBTransportProperties?
        var interfaceProtocol: UInt8?
        if IOObjectConformsTo(entry, "IOMedia") != 0 {
            role = .media
        } else if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 || IOObjectConformsTo(entry, "IOUSBDevice") != 0 {
            let deviceClass = try integerProperty(entry, key: "bDeviceClass", range: 0...255)
            role = deviceClass == 9 ? .hub : .usbDevice
            usb = try readUSBProperties(entry)
        } else if IOObjectConformsTo(entry, "IOUSBHostInterface") != 0 {
            let interfaceClass = try integerProperty(entry, key: "bInterfaceClass", range: 0...255)
            role = interfaceClass == 8 ? .storageInterface : .other
            interfaceProtocol = try integerProperty(entry, key: "bInterfaceProtocol", range: 0...255).map(UInt8.init)
        } else if IOObjectConformsTo(entry, "AppleUSBHostController") != 0 || IOObjectConformsTo(entry, "IOUSBController") != 0 {
            role = .controller
        } else if IOObjectConformsTo(entry, "AppleUSBHostPort") != 0 {
            role = .port
        } else if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 || className.hasPrefix("IOUSBMassStorage") {
            role = .storageDriver
        } else if IOObjectConformsTo(entry, "IOThunderboltDevice") != 0 || IOObjectConformsTo(entry, "IOThunderboltController") != 0 {
            role = .thunderbolt
        } else {
            role = .other
        }
        return TransportNode(
            registryEntryID: try entryID(entry),
            className: className,
            role: role,
            usb: usb,
            storageInterfaceProtocol: interfaceProtocol
        )
    }

    private func readUSBProperties(_ entry: io_registry_entry_t) throws -> USBTransportProperties {
        let descriptor = try integerProperty(entry, key: "bcdUSB", range: 0...65535).map(UInt16.init)
        if let descriptor, usbDescriptorRevision(descriptor) == nil {
            throw TransportScanError.invalidObservation(reason: "bcdUSB is not a valid binary-coded decimal revision")
        }
        return USBTransportProperties(
            productName: try stringProperty(entry, key: "USB Product Name"),
            vendorName: try stringProperty(entry, key: "USB Vendor Name"),
            vendorID: try integerProperty(entry, key: "idVendor", range: 0...65535).map(UInt16.init),
            productID: try integerProperty(entry, key: "idProduct", range: 0...65535).map(UInt16.init),
            locationID: try integerProperty(entry, key: "locationID", range: 0...Int64(UInt32.max)).map(UInt32.init),
            descriptorVersion: descriptor,
            negotiatedBitsPerSecond: try integerProperty(entry, key: "UsbLinkSpeed", range: 1...160_000_000_000),
            tunneledThroughUSB4: try booleanProperty(entry, key: "UsbTunnel")
        )
    }

    private func stringProperty(_ entry: io_registry_entry_t, key: String) throws -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        guard
            CFGetTypeID(value) == CFStringGetTypeID(),
            let string = value as? String,
            !string.isEmpty,
            string.utf8.count <= 512,
            !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw TransportScanError.invalidObservation(reason: "\(key) has an invalid type, size or control character")
        }
        return string
    }

    private func integerProperty(_ entry: io_registry_entry_t, key: String, range: ClosedRange<Int64>) throws -> Int64? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        guard
            CFGetTypeID(value) == CFNumberGetTypeID(),
            let number = value as? NSNumber,
            let integer = Int64(number.stringValue),
            range.contains(integer)
        else {
            throw TransportScanError.invalidObservation(reason: "\(key) is not an integer in the supported range")
        }
        return integer
    }

    private func booleanProperty(_ entry: io_registry_entry_t, key: String) throws -> Bool? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        guard let number = value as? NSNumber else {
            throw TransportScanError.invalidObservation(reason: "\(key) is not a Boolean flag")
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        guard CFGetTypeID(value) == CFNumberGetTypeID(), ["0", "1"].contains(number.stringValue) else {
            throw TransportScanError.invalidObservation(reason: "\(key) is not a Boolean flag or a documented 0/1 representation")
        }
        return number.intValue == 1
    }

    private func entryID(_ entry: io_registry_entry_t) throws -> UInt64 {
        var identifier: UInt64 = 0
        try checkStatus(IORegistryEntryGetRegistryEntryID(entry, &identifier), operation: "reading selected-ancestry registry ID")
        return identifier
    }

    private func IOObjectRetainChecked(_ entry: io_registry_entry_t) throws {
        try checkStatus(IOObjectRetain(entry), operation: "retaining selected block media")
    }

    private func checkStatus(_ status: kern_return_t, operation: String) throws {
        guard status == KERN_SUCCESS else {
            throw TransportScanError.registry(operation: operation, status: status)
        }
    }

    private func checkCollectionDeadline(_ deadline: TimeInterval) throws {
        if runner.isCancelled() {
            throw TroubleshooterError.cancelled
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw TransportScanError.invalidObservation(reason: "the five-second ancestry collection deadline expired")
        }
    }
}
