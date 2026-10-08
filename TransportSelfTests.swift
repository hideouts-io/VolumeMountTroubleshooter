import Foundation

/// Synthetic correlation checks are separate from the live, read-only --scan-test integration.
func runTransportSelfTests() -> Bool {
    guard
        wholeDiskIdentifier(forPhysicalStore: "disk4") == "disk4",
        wholeDiskIdentifier(forPhysicalStore: "disk4s2") == "disk4",
        wholeDiskIdentifier(forPhysicalStore: "disk40s2") == "disk40",
        wholeDiskIdentifier(forPhysicalStore: "disk9s0s2") == "disk9",
        ["disk", "disk4s", "disk-4", "/dev/disk4", "disk4s2x", "disk4ss2"].allSatisfy({ wholeDiskIdentifier(forPhysicalStore: $0) == nil }),
        usbDescriptorRevision(0x0320) == "3.20",
        usbDescriptorRevision(0x03a0) == nil
    else {
        return false
    }
    let endpoint = TransportNode(
        registryEntryID: 10,
        className: "IOUSBHostDevice",
        role: .usbDevice,
        usb: USBTransportProperties(
            productName: "Identical product name",
            vendorName: nil,
            vendorID: 0x1234,
            productID: 0x5678,
            locationID: 0x01000000,
            descriptorVersion: 0x0320,
            negotiatedBitsPerSecond: 480_000_000,
            tunneledThroughUSB4: nil
        ),
        storageInterfaceProtocol: nil
    )
    let media = TransportNode(registryEntryID: 12, className: "IOMedia", role: .media, usb: nil, storageInterfaceProtocol: nil)
    let interface = TransportNode(registryEntryID: 11, className: "IOUSBHostInterface", role: .storageInterface, usb: nil, storageInterfaceProtocol: 0x62)
    let path = PhysicalTransportPath(diskIdentifier: "disk4", busProtocol: "USB", collectedAt: Date(timeIntervalSince1970: 0), nodes: [endpoint, interface, media], deviceTreePathVerified: true)
    let disk = ExternalDisk(
        identifier: "disk4", name: "Identical product name", deviceTreePath: nil,
        busProtocol: "USB", smartStatus: "Not Supported",
        expandedSMART: .unavailable(reason: "synthetic fixture"), mediaIdentity: .observed(registryEntryID: 12), physicalTransport: .observed(path),
        size: 1000, volumes: []
    )
    let apfsVolume = transportTestVolume(identifier: "disk8s1", stores: ["disk4s2"])
    guard
        selectedPhysicalTransport(volume: apfsVolume, disk: disk) == .observed(path),
        path.storageUSBNode == endpoint,
        path.mediaRegistryEntryID == 12
    else {
        return false
    }
    for stores in [["disk40s2"], ["disk4s2", "disk6s2"], [], ["disk4s2", "disk4s2"]] {
        guard case .unavailable = selectedPhysicalTransport(volume: transportTestVolume(identifier: "disk8s1", stores: stores), disk: disk) else {
            return false
        }
    }
    let unprovenPath = PhysicalTransportPath(diskIdentifier: "disk4", busProtocol: "USB", collectedAt: path.collectedAt, nodes: [endpoint, media], deviceTreePathVerified: false)
    guard unprovenPath.storageUSBNode == nil,
          negotiatedConnectionSpeedSummary(unprovenPath).contains("unavailable"),
          !negotiatedConnectionSpeedSummary(unprovenPath).contains("480 Mb/s") else {
        return false
    }
    for identity in [PhysicalMediaIdentity.observed(registryEntryID: 99), .unavailable(reason: "native matching failed")] {
        let staleDisk = ExternalDisk(
            identifier: disk.identifier, name: disk.name, deviceTreePath: disk.deviceTreePath,
            busProtocol: disk.busProtocol, smartStatus: disk.smartStatus,
            expandedSMART: disk.expandedSMART, mediaIdentity: identity, physicalTransport: disk.physicalTransport,
            size: disk.size, volumes: disk.volumes
        )
        guard case .unavailable = selectedPhysicalTransport(volume: apfsVolume, disk: staleDisk) else {
            return false
        }
    }
    let report = physicalTransportReport(transport: .observed(path), selectedIdentifier: apfsVolume.identifier, physicalStoreIdentifiers: apfsVolume.physicalStoreIdentifiers, smartStatus: disk.smartStatus)
    let redacted = privacyRedactedReport(report, userName: "tester")
    guard
        ["registryID", "locationID", "IOUSBHostDevice", "IOUSBHostInterface", "IOMedia", "[REDACTED]"].allSatisfy({ !report.contains($0) }),
        redacted.hasSuffix(report),
        report.contains("Identical product name"),
        report.contains("480 Mb/s"),
        report.contains("USB Attached SCSI (UAS)")
    else {
        return false
    }
    let runner = CommandRunner()
    for identifier in ["disk4s1", "disk999999999"] {
        do {
            _ = try TransportScanner(runner: runner).scan(diskIdentifier: identifier, busProtocol: "USB", expectedDeviceTreePath: nil)
            return false
        } catch let error as TransportScanError {
            guard case .invalidObservation = error else {
                return false
            }
        } catch {
            return false
        }
    }
    runner.cancel()
    do {
        _ = try TransportScanner(runner: runner).scan(diskIdentifier: "disk4", busProtocol: "USB", expectedDeviceTreePath: nil)
        return false
    } catch TroubleshooterError.cancelled {
    } catch {
        return false
    }
    return true
}

private func transportTestVolume(identifier: String, stores: [String]) -> ExternalVolume {
    ExternalVolume(
        identifier: identifier, wholeDiskIdentifier: "disk4", physicalStoreIdentifiers: stores,
        name: "Synthetic APFS volume", filesystem: "APFS", mountPoint: nil,
        isEncrypted: false, isLocked: false, isWritable: false, role: nil, size: 1000
    )
}
