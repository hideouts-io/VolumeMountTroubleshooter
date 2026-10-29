import AppKit
import Foundation
import UniformTypeIdentifiers

private struct MountRequestOutcome {
    let mountResult: CommandResult
    let postcondition: StorageStateObservation
}

private struct ActiveEject {
    let generation: Int
    let volume: ExternalVolume
    let disk: ExternalDisk
    var phase: EjectPhase
}

private enum WorkbenchToolbarItem {
    static let refresh = NSToolbarItem.Identifier("refresh")
    static let stop = NSToolbarItem.Identifier("stop")
    static let reveal = NSToolbarItem.Identifier("revealVolumes")
}

private final class PendingLogDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = BoundedDiagnosticLog.empty
    private var scheduled = false
    private var generation = 0

    func enqueue(_ text: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        pending = pending.appending(text, maximumBytes: maximumReportBytes)
        guard !pending.isEmpty, !scheduled else { return nil }
        scheduled = true
        generation += 1
        return generation
    }

    func take(generation expected: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard scheduled, generation == expected else { return nil }
        let result = pending.rendered
        pending = BoundedDiagnosticLog(
            content: "",
            omittedEarlierContent: false,
            droppingPartialLine: pending.droppingPartialLine
        )
        scheduled = false
        return result
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        let result = pending.rendered
        pending = BoundedDiagnosticLog(
            content: "",
            omittedEarlierContent: false,
            droppingPartialLine: pending.droppingPartialLine
        )
        scheduled = false
        generation += 1
        return result
    }

    func endOutput() {
        lock.lock()
        pending = BoundedDiagnosticLog(
            content: pending.content,
            omittedEarlierContent: pending.omittedEarlierContent,
            droppingPartialLine: false
        )
        lock.unlock()
    }
}

func runPendingLogDeliverySelfTests() -> Bool {
    let delivery = PendingLogDelivery()
    guard let firstToken = delivery.enqueue("first"),
          delivery.enqueue(" second") == nil,
          delivery.take(generation: firstToken) == "first second",
          let boundedToken = delivery.enqueue(String(repeating: "old diagnostic line\n", count: 70_000)),
          delivery.enqueue("RESULT: UNVERIFIED\n") == nil,
          let bounded = delivery.take(generation: boundedToken) else {
        return false
    }
    let splitLine = PendingLogDelivery()
    guard let firstChunkToken = splitLine.enqueue(String(repeating: "x", count: maximumReportBytes + 1)),
          let firstChunk = splitLine.take(generation: firstChunkToken) else {
        return false
    }
    let continuationToken = splitLine.enqueue("hidden continuation")
    guard let finalChunkToken = splitLine.enqueue("\nRESULT: FAILED\n"),
          let finalChunk = splitLine.take(generation: finalChunkToken) else {
        return false
    }
    let endedLine = PendingLogDelivery()
    guard let endedLineToken = endedLine.enqueue(String(repeating: "x", count: maximumReportBytes + 1)),
          let endedLineNotice = endedLine.take(generation: endedLineToken) else {
        return false
    }
    endedLine.endOutput()
    guard let nextCommandToken = endedLine.enqueue("next command output\n"),
          let nextCommandOutput = endedLine.take(generation: nextCommandToken) else {
        return false
    }
    let ordering = PendingLogDelivery()
    guard let oldToken = ordering.enqueue("command A output") else { return false }
    let snapshot = ordering.snapshot()
    let invalidatedOldDrain = ordering.take(generation: oldToken) == nil
    guard let newToken = ordering.enqueue("command B output"),
          let newOutput = ordering.take(generation: newToken) else { return false }
    return bounded.utf8.count <= maximumReportBytes
        && bounded.hasPrefix(BoundedDiagnosticLog.omissionNotice)
        && bounded.contains("RESULT: UNVERIFIED")
        && delivery.enqueue("next") != nil
        && firstChunk == BoundedDiagnosticLog.omissionNotice
        && continuationToken == nil
        && finalChunk == "RESULT: FAILED\n"
        && endedLineNotice == BoundedDiagnosticLog.omissionNotice
        && nextCommandOutput == "next command output\n"
        && snapshot == "command A output"
        && invalidatedOldDrain
        && newOutput == "command B output"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private let runner = CommandRunner()
    private let scanRunner = CommandRunner()
    private let pendingLog = PendingLogDelivery()
    private let logPostLock = NSLock()
    private let unlockRetryLimit = 5
    private let unlockRetryDelay: TimeInterval = 2
    private var diskMonitor: DiskEventMonitor?
    private var refreshWorkItem: DispatchWorkItem?
    private var unlockRetryWorkItem: DispatchWorkItem?
    private var snapshot = DiskSnapshot(disks: [], unlockers: [], scanFailures: [])
    private var window: NSWindow?
    private var textView: NSTextView?
    private var statusLabel: NSTextField?
    private var volumePopup: NSPopUpButton?
    private var volumeDetailLabel: NSTextField?
    private var smartDetailLabel: NSTextField?
    private var connectionPathLabel: NSTextField?
    private var unlockProgressLabel: NSTextField?
    private var redactCheckbox: NSButton?
    private var inspectButton: NSButton?
    private var mountReadOnlyButton: NSButton?
    private var mountNormallyButton: NSButton?
    private var unmountButton: NSButton?
    private var stopButton: NSButton?
    private var refreshButton: NSButton?
    private var ejectButton: NSButton?
    private var showUnlockerButton: NSButton?
    private var copyButton: NSButton?
    private var saveButton: NSButton?
    private var revealButton: NSButton?
    private var completeLog = BoundedDiagnosticLog.empty
    private var isRunning = false
    private var operationGeneration = 0
    private var activeEject: ActiveEject?
    private var isRefreshing = false
    private var scanGeneration = 0
    private var automaticRefreshPending = false
    private var selectionRequiresUserChoice = false
    private var unlockRetryAttempt = 0
    private var trackedUnlocker: VirtualUnlocker?
    private var readyUnlockVolumeIdentifier: String?
    private var lastUnlockProgressMessage: String?
    private var postRefreshStatus: (message: String, color: NSColor)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureWindow()
        startDiskMonitoring()
        refreshVolumes(automatic: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ application: NSApplication) -> Bool {
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
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Volume Mount Troubleshooter"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isRestorable = false
        window.center()
        window.minSize = NSSize(width: 820, height: 600)

        let rootView = NSView()
        window.contentView = rootView

        let titleLabel = NSTextField(labelWithString: "Volume Mount Troubleshooter")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "Inspect external storage read-only. Disk actions require confirmation; no erase, format, or repair."
        )
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let logoImageView = NSImageView()
        logoImageView.image = NSApp.applicationIconImage
        logoImageView.imageAlignment = .alignCenter
        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        logoImageView.setAccessibilityLabel("Volume Mount Troubleshooter logo")
        logoImageView.setContentHuggingPriority(.required, for: .horizontal)
        logoImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [logoImageView, titleStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12

        let selectorLabel = NSTextField(labelWithString: "SELECTED EXTERNAL VOLUME")
        selectorLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        selectorLabel.textColor = .secondaryLabelColor

        let volumePopup = NSPopUpButton()
        volumePopup.setAccessibilityIdentifier("volumeSelector")
        volumePopup.addItem(withTitle: "Scanning for external volumes…")
        volumePopup.isEnabled = false
        volumePopup.target = self
        volumePopup.action = #selector(volumeSelectionChanged)
        self.volumePopup = volumePopup

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed))
        refreshButton.setAccessibilityIdentifier("refreshButton")
        refreshButton.bezelStyle = .rounded
        self.refreshButton = refreshButton

        let selectorStack = NSStackView(views: [selectorLabel, volumePopup])
        selectorStack.orientation = .horizontal
        selectorStack.spacing = 8
        selectorStack.alignment = .centerY
        volumePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let volumeDetailLabel = NSTextField(wrappingLabelWithString: "Scanning for external volumes…")
        volumeDetailLabel.textColor = .secondaryLabelColor
        volumeDetailLabel.font = NSFont.systemFont(ofSize: 12)
        self.volumeDetailLabel = volumeDetailLabel

        let smartDetailLabel = NSTextField(wrappingLabelWithString: "")
        smartDetailLabel.textColor = .secondaryLabelColor
        smartDetailLabel.font = NSFont.systemFont(ofSize: 12)
        smartDetailLabel.isHidden = true
        self.smartDetailLabel = smartDetailLabel

        let connectionPathLabel = NSTextField(wrappingLabelWithString: "")
        connectionPathLabel.textColor = .secondaryLabelColor
        connectionPathLabel.font = NSFont.systemFont(ofSize: 12)
        connectionPathLabel.isSelectable = true
        connectionPathLabel.isHidden = true
        connectionPathLabel.setAccessibilityIdentifier("connectionPath")
        self.connectionPathLabel = connectionPathLabel

        let unlockProgressLabel = NSTextField(wrappingLabelWithString: "")
        unlockProgressLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        unlockProgressLabel.textColor = .systemOrange
        unlockProgressLabel.isHidden = true
        self.unlockProgressLabel = unlockProgressLabel

        let redactCheckbox = NSButton(checkboxWithTitle: "Redact copied/saved reports", target: self, action: nil)
        redactCheckbox.setAccessibilityIdentifier("redactSharedReports")
        redactCheckbox.state = .on
        self.redactCheckbox = redactCheckbox

        let statusLabel = NSTextField(labelWithString: "Scanning…")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        self.statusLabel = statusLabel

        let selectionDetails = NSStackView(views: [
            selectorStack,
            volumeDetailLabel,
            smartDetailLabel,
            connectionPathLabel,
            unlockProgressLabel,
            statusLabel
        ])
        selectionDetails.orientation = .vertical
        selectionDetails.alignment = .leading
        selectionDetails.spacing = 6

        let inspectionLabel = NSTextField(labelWithString: "READ-ONLY INSPECTION")
        inspectionLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        inspectionLabel.textColor = .secondaryLabelColor

        let operationsLabel = NSTextField(labelWithString: "DISK OPERATIONS")
        operationsLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        operationsLabel.textColor = .secondaryLabelColor

        let inspectButton = NSButton(title: "Inspect", target: self, action: #selector(inspectSelectedVolume))
        inspectButton.bezelStyle = .rounded
        inspectButton.controlSize = .large
        inspectButton.keyEquivalent = "\r"
        inspectButton.identifier = NSUserInterfaceItemIdentifier("inspectButton")
        inspectButton.setAccessibilityIdentifier("inspectButton")
        inspectButton.toolTip = "Collect read-only disk, volume, USB, SMART, encryption, and Disk Arbitration evidence."
        inspectButton.isEnabled = false
        self.inspectButton = inspectButton

        let mountReadOnlyButton = NSButton(
            title: "Mount Read-Only",
            target: self,
            action: #selector(mountSelectedVolumeReadOnly)
        )
        mountReadOnlyButton.bezelStyle = .rounded
        mountReadOnlyButton.identifier = NSUserInterfaceItemIdentifier("mountReadOnlyButton")
        mountReadOnlyButton.toolTip = "Mount the selected volume read-only and verify that macOS reports it as non-writable."
        mountReadOnlyButton.isEnabled = false
        self.mountReadOnlyButton = mountReadOnlyButton

        let mountNormallyButton = NSButton(
            title: "Mount Normally",
            target: self,
            action: #selector(mountSelectedVolumeNormally)
        )
        mountNormallyButton.bezelStyle = .rounded
        mountNormallyButton.identifier = NSUserInterfaceItemIdentifier("mountNormallyButton")
        mountNormallyButton.toolTip = "Mount the selected unmounted volume normally and verify its mount point."
        mountNormallyButton.isEnabled = false
        self.mountNormallyButton = mountNormallyButton

        let unmountButton = NSButton(
            title: "Unmount Volume",
            target: self,
            action: #selector(unmountSelectedVolume)
        )
        unmountButton.bezelStyle = .rounded
        unmountButton.identifier = NSUserInterfaceItemIdentifier("unmountVolumeButton")
        unmountButton.toolTip = "Unmount only the selected volume without ejecting its physical disk."
        unmountButton.isEnabled = false
        self.unmountButton = unmountButton

        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stopTroubleshooting))
        stopButton.setAccessibilityIdentifier("stopButton")
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false
        self.stopButton = stopButton

        let ejectButton = NSButton(title: "Safe Eject Disk", target: self, action: #selector(ejectSelectedDisk))
        ejectButton.bezelStyle = .rounded
        ejectButton.identifier = NSUserInterfaceItemIdentifier("safeEjectDiskButton")
        ejectButton.toolTip = "Eject the selected volume's whole physical disk after confirmation."
        ejectButton.isEnabled = false
        self.ejectButton = ejectButton

        let showUnlockerButton = NSButton(
            title: "Show Unlocker in Finder",
            target: self,
            action: #selector(showUnlockerInFinder)
        )
        showUnlockerButton.bezelStyle = .rounded
        showUnlockerButton.identifier = NSUserInterfaceItemIdentifier("showUnlockerInFinderButton")
        showUnlockerButton.isEnabled = false
        showUnlockerButton.isHidden = true
        self.showUnlockerButton = showUnlockerButton

        let copyButton = NSButton(title: "Copy Report", target: self, action: #selector(copyLog))
        copyButton.bezelStyle = .rounded
        copyButton.setAccessibilityIdentifier("copyReportButton")
        copyButton.isEnabled = false
        self.copyButton = copyButton

        let saveButton = NSButton(title: "Save Report…", target: self, action: #selector(saveReport))
        saveButton.bezelStyle = .rounded
        saveButton.setAccessibilityIdentifier("saveReportButton")
        saveButton.isEnabled = false
        self.saveButton = saveButton

        let revealButton = NSButton(title: "Show Volumes", target: self, action: #selector(revealVolumes))
        revealButton.bezelStyle = .rounded
        revealButton.setAccessibilityIdentifier("showVolumesButton")
        self.revealButton = revealButton

        let inspectionStack = NSStackView(views: [inspectionLabel, inspectButton])
        inspectionStack.orientation = .vertical
        inspectionStack.alignment = .leading
        inspectionStack.spacing = 6

        let operationButtons = NSStackView(views: [
            mountReadOnlyButton,
            mountNormallyButton,
            unmountButton,
            ejectButton,
        ])
        operationButtons.orientation = .horizontal
        operationButtons.spacing = 8
        operationButtons.alignment = .centerY
        [mountReadOnlyButton, mountNormallyButton, unmountButton, ejectButton].forEach {
            $0.controlSize = .small
        }

        let operationsStack = NSStackView(views: [operationsLabel, operationButtons])
        operationsStack.orientation = .vertical
        operationsStack.alignment = .leading
        operationsStack.spacing = 6

        let actionStack = NSStackView(views: [inspectionStack, operationsStack])
        actionStack.orientation = .horizontal
        actionStack.spacing = 20
        actionStack.alignment = .top

        let reportLabel = NSTextField(labelWithString: "LIVE COMMAND OUTPUT")
        reportLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        reportLabel.textColor = .secondaryLabelColor

        let reportSpacer = NSView()
        reportSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let reportHeader = NSStackView(views: [
            reportLabel,
            reportSpacer,
            redactCheckbox,
            copyButton,
            saveButton
        ])
        reportHeader.orientation = .horizontal
        reportHeader.spacing = 8
        reportHeader.alignment = .centerY

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .lineBorder

        let textView = NSTextView()
        textView.setAccessibilityIdentifier("diagnosticConsole")
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        self.textView = textView

        let toolbar = NSToolbar(identifier: "WorkbenchToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let contentStack = NSStackView(views: [
            headerStack,
            selectionDetails,
            actionStack,
            showUnlockerButton,
            reportHeader,
            scrollView
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(contentStack)

        [
            logoImageView,
            titleStack,
            headerStack,
            titleLabel,
            subtitleLabel,
            selectionDetails,
            selectorStack,
            volumeDetailLabel,
            smartDetailLabel,
            connectionPathLabel,
            unlockProgressLabel,
            statusLabel,
            inspectionStack,
            operationsStack,
            operationButtons,
            actionStack,
            reportHeader,
            scrollView
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            logoImageView.widthAnchor.constraint(equalToConstant: 48),
            logoImageView.heightAnchor.constraint(equalToConstant: 48),
            headerStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: titleStack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: titleStack.widthAnchor),
            selectionDetails.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            selectorStack.widthAnchor.constraint(equalTo: selectionDetails.widthAnchor),
            volumeDetailLabel.widthAnchor.constraint(equalTo: selectionDetails.widthAnchor),
            smartDetailLabel.widthAnchor.constraint(equalTo: selectionDetails.widthAnchor),
            connectionPathLabel.widthAnchor.constraint(equalTo: selectionDetails.widthAnchor),
            unlockProgressLabel.widthAnchor.constraint(equalTo: selectionDetails.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: selectionDetails.widthAnchor),
            actionStack.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor),
            reportHeader.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [WorkbenchToolbarItem.refresh, WorkbenchToolbarItem.stop, .flexibleSpace, WorkbenchToolbarItem.reveal]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let button: NSButton
        let symbolName: String
        switch itemIdentifier {
        case WorkbenchToolbarItem.refresh:
            guard let refreshButton else { return nil }
            button = refreshButton
            symbolName = "arrow.clockwise"
        case WorkbenchToolbarItem.stop:
            guard let stopButton else { return nil }
            button = stopButton
            symbolName = "stop.fill"
        case WorkbenchToolbarItem.reveal:
            guard let revealButton else { return nil }
            button = revealButton
            symbolName = "externaldrive"
        default:
            return nil
        }

        button.controlSize = .small
        button.setAccessibilityLabel(button.title)
        button.toolTip = button.title
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.title) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = button.title
        item.paletteLabel = button.title
        item.view = button
        return item
    }

    private func startDiskMonitoring() {
        let monitor = DiskEventMonitor { [weak self] event in
            DispatchQueue.main.async {
                self?.handleDiskArbitrationEvent(event)
            }
        }
        do {
            try monitor.start()
            diskMonitor = monitor
        } catch {
            appendLog("AUTOMATIC DETECTION WARNING: \(error.localizedDescription)\n")
        }
    }

    private func handleDiskArbitrationEvent(_ event: DiskArbitrationEvent) {
        switch event {
        case .appeared:
            scheduleAutomaticRefresh()
        case let .disappeared(identifier):
            handleDiskDisappearance(identifier: identifier)
        }
    }

    private func handleDiskDisappearance(identifier: String) {
        let selectedIdentifier = selectedVolume()?.identifier
        let scanWasRunning = isRefreshing
        let updatedSnapshot = snapshot.removingDevice(identifier: identifier)
        let selectedWasRemoved = selectedIdentifier.map { selected in
            !updatedSnapshot.volumes.contains { $0.identifier == selected }
        } ?? false
        let trackedUnlockerWasRemoved = trackedUnlocker.map { unlocker in
            !updatedSnapshot.unlockers.contains(unlocker)
        } ?? false
        let isExpectedEjectDisappearance = selectedWasRemoved && isRunning && activeEject.map { eject in
            let phase = eject.phase == .launching && runner.hasLaunchedCommand(
                executable: "/usr/sbin/diskutil",
                arguments: ["eject", "/dev/\(eject.disk.identifier)"]
            ) ? EjectPhase.inFlight : eject.phase
            return eject.generation == operationGeneration && expectedEjectDisappearance(
                identifier: identifier,
                volume: eject.volume,
                disk: eject.disk,
                phase: phase
            )
        } == true
        if selectedWasRemoved {
            selectionRequiresUserChoice = true
            if isRunning {
                if isExpectedEjectDisappearance {
                    appendLog("EJECT TRANSITION: selected storage disappeared; recording the action result and diagnostic coverage.\n")
                } else {
                    runner.cancel()
                    appendLog("SELECTED STORAGE DISCONNECTED: stopping the operation; select the device again after it reappears.\n")
                }
            }
        }

        scanGeneration += 1
        if scanWasRunning {
            automaticRefreshPending = true
            scanRunner.cancel()
        }

        snapshot = updatedSnapshot
        renderSelectorAfterDisappearance(
            previouslySelectedIdentifier: selectedIdentifier,
            selectedWasRemoved: selectedWasRemoved
        )
        if trackedUnlockerWasRemoved {
            clearUnlockTransition()
        } else {
            updateUnlockTransition()
        }
        updateSelectionDetails()
        setControlsForRunningState(isRunning)
        if selectedWasRemoved {
            if !isExpectedEjectDisappearance {
                setStatus("Selected storage disconnected — choose the volume again", color: .systemOrange)
            }
            if !isRunning {
                appendLog("SELECTED STORAGE DISCONNECTED: /dev/\(identifier) disappeared; the selected volume was cleared.\n")
            }
        }

        if !scanWasRunning {
            scheduleAutomaticRefresh()
        }
    }

    private func renderSelectorAfterDisappearance(
        previouslySelectedIdentifier: String?,
        selectedWasRemoved: Bool
    ) {
        volumePopup?.removeAllItems()
        if selectedWasRemoved {
            let placeholder = snapshot.volumes.isEmpty
                ? "No external volumes detected"
                : "Select another external volume"
            volumePopup?.addItem(withTitle: placeholder)
            volumePopup?.lastItem?.tag = -1
        }
        addCurrentVolumeItemsToPopup()

        if
            !selectedWasRemoved,
            let previouslySelectedIdentifier,
            let item = volumePopup?.itemArray.first(where: { item in
                let tag = item.tag
                return snapshot.volumes.indices.contains(tag)
                    && snapshot.volumes[tag].identifier == previouslySelectedIdentifier
            })
        {
            volumePopup?.select(item)
        } else if selectedWasRemoved {
            volumePopup?.selectItem(at: 0)
        } else if snapshot.volumes.isEmpty {
            volumePopup?.addItem(withTitle: "No external volumes detected")
            volumePopup?.lastItem?.tag = -1
            volumePopup?.selectItem(at: 0)
        }
    }

    private func addCurrentVolumeItemsToPopup() {
        for (index, volume) in snapshot.volumes.enumerated() {
            volumePopup?.addItem(withTitle: volumeMenuTitle(volume))
            volumePopup?.lastItem?.tag = index
        }
    }

    private func scheduleAutomaticRefresh() {
        if isRunning || isRefreshing {
            automaticRefreshPending = true
            return
        }
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshVolumes(automatic: true)
        }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    @objc private func refreshPressed() {
        unlockRetryAttempt = 0
        unlockRetryWorkItem?.cancel()
        unlockRetryWorkItem = nil
        refreshVolumes(automatic: false)
    }

    private func refreshVolumes(automatic: Bool) {
        guard !isRunning else {
            if automatic {
                automaticRefreshPending = true
            }
            return
        }
        guard !isRefreshing else {
            if automatic {
                automaticRefreshPending = true
            }
            return
        }
        if automatic {
            automaticRefreshPending = false
        }
        scanGeneration += 1
        let currentScanGeneration = scanGeneration
        isRefreshing = true
        setControlsForRunningState(isRunning)
        setStatus(automatic ? "Checking for attached volumes…" : "Refreshing external volumes…", color: .systemBlue)
        let previousIdentifiers = Set(snapshot.volumes.map(\.identifier))
        let selectedIdentifier = selectedVolume()?.identifier
        let scanner = DiskScanner(runner: scanRunner)
        scanRunner.reset()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let newSnapshot = try scanner.scan { _ in }
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    guard self.scanGeneration == currentScanGeneration else {
                        self.finishSupersededScan()
                        return
                    }
                    guard !self.scanRunner.isCancelled() else {
                        self.finishCancelledScan(generation: currentScanGeneration)
                        return
                    }
                    self.applySnapshot(
                        newSnapshot,
                        selectedIdentifier: selectedIdentifier,
                        previousIdentifiers: previousIdentifiers,
                        automatic: automatic
                    )
                }
            } catch TroubleshooterError.cancelled {
                DispatchQueue.main.async {
                    self?.finishCancelledScan(generation: currentScanGeneration)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    switch error {
                    case TroubleshooterError.commandTerminationFailed, TroubleshooterError.commandOutputFailed:
                        self.refreshWorkItem?.cancel()
                        self.refreshWorkItem = nil
                        self.unlockRetryWorkItem?.cancel()
                        self.unlockRetryWorkItem = nil
                        self.automaticRefreshPending = false
                        self.postRefreshStatus = nil
                        self.showScanFailure(error: error)
                        return
                    default:
                        break
                    }
                    guard self.scanGeneration == currentScanGeneration else {
                        self.finishSupersededScan()
                        return
                    }
                    guard !self.scanRunner.isCancelled() else {
                        self.finishCancelledScan(generation: currentScanGeneration)
                        return
                    }
                    self.showScanFailure(error: error)
                    self.updateUnlockTransition()
                    self.runPendingAutomaticRefreshIfNeeded()
                }
            }
        }
    }

    private func showScanFailure(error: Error) {
        isRefreshing = false
        setStatus("Volume scan failed: \(error.localizedDescription)", color: .systemRed)
        appendLog("SCAN FAILURE: \(error.localizedDescription)\n")
        setControlsForRunningState(isRunning)
    }

    private func finishCancelledScan(generation: Int) {
        guard scanGeneration == generation else {
            finishSupersededScan()
            return
        }
        isRefreshing = false
        automaticRefreshPending = false
        postRefreshStatus = nil
        setControlsForRunningState(isRunning)
        setStatus("Volume scan cancelled — press Refresh to try again", color: .systemOrange)
        appendLog("\nRESULT: CANCELLED — volume scan stopped\n")
    }

    private func finishSupersededScan() {
        isRefreshing = false
        refreshButton?.isEnabled = true
        setControlsForRunningState(isRunning)
        runPendingAutomaticRefreshIfNeeded()
    }

    private func applySnapshot(
        _ newSnapshot: DiskSnapshot,
        selectedIdentifier: String?,
        previousIdentifiers: Set<String>,
        automatic: Bool
    ) {
        if let selectedIdentifier {
            let oldDisk = snapshot.volumes.first { $0.identifier == selectedIdentifier }
                .flatMap { snapshot.disk(containing: $0) }
            let newDisk = newSnapshot.volumes.first { $0.identifier == selectedIdentifier }
                .flatMap { newSnapshot.disk(containing: $0) }
            if newDisk == nil || oldDisk?.mediaIdentity != newDisk?.mediaIdentity {
                selectionRequiresUserChoice = true
            }
        }
        snapshot = newSnapshot
        volumePopup?.removeAllItems()
        if selectionRequiresUserChoice, !newSnapshot.volumes.isEmpty {
            volumePopup?.addItem(withTitle: "Select an external volume")
            volumePopup?.lastItem?.tag = -1
            addCurrentVolumeItemsToPopup()
            volumePopup?.selectItem(at: 0)
        } else {
            addCurrentVolumeItemsToPopup()
            if
                let selectedIdentifier,
                let item = volumePopup?.itemArray.first(where: { item in
                    let tag = item.tag
                    return newSnapshot.volumes.indices.contains(tag)
                        && newSnapshot.volumes[tag].identifier == selectedIdentifier
                })
            {
                volumePopup?.select(item)
            } else if !newSnapshot.volumes.isEmpty {
                volumePopup?.selectItem(at: 0)
            } else {
                volumePopup?.addItem(withTitle: "No external volumes detected")
                volumePopup?.lastItem?.tag = -1
                volumePopup?.selectItem(at: 0)
            }
        }

        isRefreshing = false
        refreshButton?.isEnabled = true
        updateUnlockTransition()
        updateSelectionDetails()
        if let postRefreshStatus {
            setStatus(postRefreshStatus.message, color: postRefreshStatus.color)
            self.postRefreshStatus = nil
        } else if !newSnapshot.scanFailures.isEmpty {
            let failedDiskCount = newSnapshot.scanFailures.count
            if newSnapshot.volumes.isEmpty {
                setStatus(
                    "Disk inventory incomplete — \(failedDiskCount) external disk(s) failed; see console",
                    color: .systemRed
                )
            } else {
                setStatus(
                    "Partial inventory — \(failedDiskCount) disk(s) failed; usable volumes remain available",
                    color: .systemOrange
                )
            }
        }
        appendScanFailures(newSnapshot.scanFailures)
        setControlsForRunningState(false)

        let currentIdentifiers = Set(newSnapshot.volumes.map(\.identifier))
        if automatic, !previousIdentifiers.isEmpty, currentIdentifiers != previousIdentifiers {
            let added = currentIdentifiers.subtracting(previousIdentifiers).sorted()
            let removed = previousIdentifiers.subtracting(currentIdentifiers).sorted()
            if !added.isEmpty {
                appendLog("AUTO-DETECT: attached volume device(s): \(added.joined(separator: ", "))\n")
            }
            if !removed.isEmpty {
                appendLog("AUTO-DETECT: removed volume device(s): \(removed.joined(separator: ", "))\n")
            }
        }
        runPendingAutomaticRefreshIfNeeded()
    }

    private func appendScanFailures(_ failures: [DiskScanFailure]) {
        for failure in failures {
            appendLog(
                "\nDISK INVENTORY FAILURE: /dev/\(failure.diskIdentifier)\n\(failure.errorDescription)\n"
            )
        }
    }

    private func updateUnlockTransition() {
        unlockRetryWorkItem?.cancel()
        unlockRetryWorkItem = nil

        if let detectedUnlocker = snapshot.unlockers.first {
            let isNewUnlocker = trackedUnlocker?.deviceTreePath != detectedUnlocker.deviceTreePath
                || trackedUnlocker?.wholeDiskIdentifier != detectedUnlocker.wholeDiskIdentifier
            trackedUnlocker = detectedUnlocker
            if isNewUnlocker {
                unlockRetryAttempt = 0
                readyUnlockVolumeIdentifier = nil
                lastUnlockProgressMessage = nil
                setUnlockProgress(.detected, color: .systemOrange)
            }
        }

        guard let trackedUnlocker else {
            clearUnlockTransitionUI()
            return
        }

        if let readyVolume = snapshot.dataVolume(matching: trackedUnlocker) {
            readyUnlockVolumeIdentifier = readyVolume.identifier
            setUnlockProgress(.ready(volumeName: readyVolume.name), color: .systemGreen)
            updateShowUnlockerButton()
            return
        }

        let relatedDiskStillPresent = snapshot.disks.contains { disk in
            guard let deviceTreePath = nonEmpty(trackedUnlocker.deviceTreePath) else {
                return false
            }
            return disk.deviceTreePath == deviceTreePath
        }
        if readyUnlockVolumeIdentifier != nil, snapshot.unlockers.isEmpty, !relatedDiskStillPresent {
            clearUnlockTransition()
            return
        }

        readyUnlockVolumeIdentifier = nil
        if unlockRetryAttempt >= unlockRetryLimit {
            setUnlockProgress(.exhausted(limit: unlockRetryLimit), color: .systemRed)
            updateShowUnlockerButton()
            return
        }

        if unlockRetryAttempt == 0 {
            setUnlockProgress(.waiting, color: .systemOrange)
        }
        updateShowUnlockerButton()
        scheduleNextUnlockRetry()
    }

    private func scheduleNextUnlockRetry() {
        guard trackedUnlocker != nil, unlockRetryAttempt < unlockRetryLimit else {
            return
        }
        let nextAttempt = unlockRetryAttempt + 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.trackedUnlocker != nil else {
                return
            }
            self.unlockRetryWorkItem = nil
            self.unlockRetryAttempt = nextAttempt
            self.setUnlockProgress(
                .retry(attempt: nextAttempt, limit: self.unlockRetryLimit),
                color: .systemOrange
            )
            self.refreshVolumes(automatic: true)
        }
        unlockRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + unlockRetryDelay, execute: workItem)
    }

    private func setUnlockProgress(_ phase: UnlockTransitionPhase, color: NSColor) {
        let message = phase.message
        unlockProgressLabel?.stringValue = message
        unlockProgressLabel?.textColor = color
        unlockProgressLabel?.isHidden = false
        if lastUnlockProgressMessage != message {
            appendLog("UNLOCK PROGRESSION: \(message)\n")
            lastUnlockProgressMessage = message
        }
    }

    private func clearUnlockTransition() {
        unlockRetryWorkItem?.cancel()
        unlockRetryWorkItem = nil
        unlockRetryAttempt = 0
        trackedUnlocker = nil
        readyUnlockVolumeIdentifier = nil
        lastUnlockProgressMessage = nil
        clearUnlockTransitionUI()
    }

    private func clearUnlockTransitionUI() {
        unlockProgressLabel?.stringValue = ""
        unlockProgressLabel?.isHidden = true
        showUnlockerButton?.isEnabled = false
        showUnlockerButton?.isHidden = true
        showUnlockerButton?.toolTip = nil
    }

    private func updateShowUnlockerButton() {
        guard let trackedUnlocker else {
            clearUnlockTransitionUI()
            return
        }
        showUnlockerButton?.isHidden = false
        let hasMountPoint = nonEmpty(trackedUnlocker.mountPoint) != nil
        showUnlockerButton?.isEnabled = !isRunning && !isRefreshing && hasMountPoint
        showUnlockerButton?.toolTip = hasMountPoint
            ? "Reveal the mounted vendor unlocker volume in Finder without opening its application."
            : "The vendor unlocker volume is not currently mounted."
    }

    private func runPendingAutomaticRefreshIfNeeded() {
        guard automaticRefreshPending, !isRunning, !isRefreshing else {
            return
        }
        automaticRefreshPending = false
        appendLog("AUTO-DETECT: storage changed during the previous scan; running a follow-up refresh.\n")
        scheduleAutomaticRefresh()
    }

    @objc private func volumeSelectionChanged() {
        if selectedVolume() != nil {
            selectionRequiresUserChoice = false
        }
        updateSelectionDetails()
        setControlsForRunningState(false)
    }

    private func updateSelectionDetails() {
        guard let volume = selectedVolume(), let disk = snapshot.disk(containing: volume) else {
            smartDetailLabel?.stringValue = ""
            smartDetailLabel?.isHidden = true
            connectionPathLabel?.stringValue = ""
            connectionPathLabel?.toolTip = nil
            connectionPathLabel?.isHidden = true
            if let trackedUnlocker {
                volumeDetailLabel?.stringValue = "Detected \(trackedUnlocker.name), which is the vendor unlock helper rather than the data volume. No application or credential prompt is opened automatically."
                setStatus("Unlock helper detected — waiting for the data volume", color: .systemOrange)
            } else {
                volumeDetailLabel?.stringValue = "No user-facing external volume detected."
                setStatus("Attach an external volume, then press Refresh", color: .systemOrange)
            }
            return
        }

        let mountState = volume.mountPoint.map { "Mounted at \($0)" } ?? "Not mounted"
        let encryptionState = encryptionStateSummary(volume)
        let role = volume.role.map { " • APFS role: \($0)" } ?? ""
        volumeDetailLabel?.stringValue = "\(mountState) • \(encryptionState) • \(formattedByteCount(volume.size)) • \(disk.busProtocol) • SMART: \(disk.smartStatus)\(role)"
        let smartLines = [
            expandedSMARTSummary(disk.expandedSMART),
            expandedSMARTCaveat(disk.expandedSMART)
        ].compactMap { $0 }
        smartDetailLabel?.stringValue = smartLines.joined(separator: "\n")
        smartDetailLabel?.isHidden = false
        let transport = selectedPhysicalTransport(volume: volume, disk: disk)
        connectionPathLabel?.stringValue = physicalConnectionSummary(transport)
        connectionPathLabel?.toolTip = physicalTransportReport(
            transport: transport,
            selectedIdentifier: volume.identifier,
            physicalStoreIdentifiers: volume.physicalStoreIdentifiers,
            smartStatus: disk.smartStatus
        )
        connectionPathLabel?.isHidden = false
        setStatus("Ready — choose an explicit action for the selected volume", color: .labelColor)
    }

    private func selectedVolume() -> ExternalVolume? {
        guard let index = volumePopup?.selectedItem?.tag, snapshot.volumes.indices.contains(index) else {
            return nil
        }
        return snapshot.volumes[index]
    }

    @objc private func inspectSelectedVolume() {
        guard !isRunning, !isRefreshing, let volume = selectedVolume(), let disk = snapshot.disk(containing: volume) else {
            return
        }
        guard volumeActionAvailability(for: volume).inspect else {
            return
        }

        beginOperation(status: "Inspecting \(volume.name)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performInspection(volume: volume, disk: disk, runner: self?.runner)
        }
    }

    @objc private func mountSelectedVolumeReadOnly() {
        guard !isRunning, !isRefreshing, let volume = selectedVolume(), let disk = snapshot.disk(containing: volume) else {
            return
        }
        guard volumeActionAvailability(for: volume).mountReadOnly else {
            return
        }
        let requiresReadOnlyRemount = nonEmpty(volume.mountPoint) != nil && volume.isWritable == true
        let confirmed: Bool = requiresReadOnlyRemount
            ? confirmReadOnlyRemount(volume: volume)
            : confirmDiskAction(
                title: "Mount \(volume.name) read-only?",
                explanation: "macOS will mount only the selected volume read-only and verify that it is not writable.",
                buttonTitle: "Mount Read-Only"
            )
        guard confirmed else {
            return
        }

        beginOperation(status: "Mounting \(volume.name) read-only…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performReadOnlyMount(volume: volume, disk: disk, runner: self?.runner)
        }
    }

    @objc private func mountSelectedVolumeNormally() {
        guard !isRunning, !isRefreshing, let volume = selectedVolume(), let disk = snapshot.disk(containing: volume) else {
            return
        }
        guard volumeActionAvailability(for: volume).mountNormally else {
            return
        }
        guard confirmDiskAction(
            title: "Mount \(volume.name) normally?",
            explanation: "macOS will mount only the selected volume using its normal write policy.",
            buttonTitle: "Mount Normally"
        ) else {
            return
        }

        beginOperation(status: "Mounting \(volume.name) normally…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performNormalMount(volume: volume, disk: disk, runner: self?.runner)
        }
    }

    @objc private func unmountSelectedVolume() {
        guard !isRunning, !isRefreshing, let volume = selectedVolume(), let disk = snapshot.disk(containing: volume) else {
            return
        }
        guard volumeActionAvailability(for: volume).unmountVolume else {
            return
        }
        guard confirmDiskAction(
            title: "Unmount \(volume.name)?",
            explanation: "macOS will unmount only the selected volume. Close files using it first.",
            buttonTitle: "Unmount Volume"
        ) else {
            return
        }

        beginOperation(status: "Unmounting \(volume.name)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performUnmount(volume: volume, disk: disk, runner: self?.runner)
        }
    }

    private func beginOperation(status: String) {
        operationGeneration += 1
        activeEject = nil
        isRunning = true
        completeLog = .empty
        textView?.string = ""
        runner.reset()
        setControlsForRunningState(true)
        setStatus(status, color: .systemBlue)
    }

    private func confirmReadOnlyRemount(volume: ExternalVolume) -> Bool {
        confirmDiskAction(
            title: "Remount \(volume.name) read-only?",
            explanation: "The selected volume is currently mounted writable. macOS must unmount only this volume before mounting it read-only. Close files using it first.",
            buttonTitle: "Unmount and Remount"
        )
    }

    private func confirmDiskAction(title: String, explanation: String, buttonTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = explanation
        alert.alertStyle = .warning
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func stopTroubleshooting() {
        automaticRefreshPending = false
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        unlockRetryWorkItem?.cancel()
        unlockRetryWorkItem = nil
        if let eject = activeEject {
            activeEject?.phase = ejectPhaseAfterStop(eject.phase)
        }
        runner.cancel()
        scanRunner.cancel()
        stopButton?.isEnabled = false
        appendLog("\nStop requested. Terminating the active command…\n")
        setStatus("Stopping…", color: .systemOrange)
    }

    @objc private func ejectSelectedDisk() {
        guard
            !isRunning,
            !isRefreshing,
            let volume = selectedVolume(),
            let disk = snapshot.disk(containing: volume)
        else {
            return
        }
        guard volumeActionAvailability(for: volume).safeEjectDisk else {
            return
        }
        guard confirmDiskAction(
            title: "Safely eject /dev/\(volume.wholeDiskIdentifier)?",
            explanation: "This ejects the whole external physical disk, including any sibling volumes. Close files using them first.",
            buttonTitle: "Safe Eject Disk"
        ) else {
            return
        }

        beginOperation(status: "Ejecting external disk…")
        let generation = operationGeneration
        activeEject = ActiveEject(
            generation: generation,
            volume: volume,
            disk: disk,
            phase: .preflight
        )
        let devicePath = "/dev/\(volume.wholeDiskIdentifier)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performEject(volume: volume, disk: disk, devicePath: devicePath, generation: generation)
        }
    }

    nonisolated private func performEject(
        volume: ExternalVolume,
        disk: ExternalDisk,
        devicePath: String,
        generation: Int
    ) {
        postOperationHeader(action: "Safe Eject Disk", volume: volume, disk: disk)
        var mutationRequested = false
        do {
            _ = try validatedSelectedVolume(volume: volume, disk: disk, runner: runner)
            guard case let .observed(expectedID) = disk.mediaIdentity else {
                throw TroubleshooterError.selectedStorageChanged(reason: "the selected disk has no captured IOMedia identity")
            }
            try markEjectLaunching(generation: generation)
            let result = try runLogged(
                executable: "/usr/sbin/diskutil",
                arguments: ["eject", devicePath],
                runner: runner,
                onLaunch: { [weak self] in
                    mutationRequested = true
                    self?.markEjectCommandStarted(generation: generation)
                }
            )
            let presence = observeEjectedMedia(
                diskIdentifier: disk.identifier,
                expectedRegistryEntryID: expectedID,
                runner: runner
            )
            postEjectObservation(presence, devicePath: devicePath)
            markEjectPostconditionObserved(generation: generation)
            appendOptionalDiskArbitrationErrors(volume: volume, runner: runner)
            if result.exitStatus != 0 {
                postLog(guidedFailureExplanation(exitStatus: result.exitStatus, output: result.output, volume: volume) + "\n")
            }
            let outcome = ejectOutcome(exitStatus: result.exitStatus, mediaPresence: presence)
            let message: String
            switch outcome {
            case .success:
                message = "Safely ejected \(devicePath); original media is absent"
            case .failed:
                message = "Eject command exited \(result.exitStatus); original media is still present"
            case .unverified:
                message = "Eject command exited \(result.exitStatus); final state of the original media is unverified"
            }
            postEjectCompletion(generation: generation, outcome: outcome, message: message, mutationRequested: true)
        } catch TroubleshooterError.cancelled {
            if mutationRequested {
                postEjectCompletion(
                    generation: generation,
                    outcome: .unverified,
                    message: "Stopped after the eject command was requested; verify the disk state",
                    mutationRequested: true
                )
            } else {
                postEjectCompletion(generation: generation, outcome: nil, message: "Operation stopped before eject", mutationRequested: false)
            }
        } catch {
            postLog("FATAL: \(error.localizedDescription)\n")
            postEjectCompletion(
                generation: generation,
                outcome: mutationRequested ? .unverified : .failed,
                message: mutationRequested
                    ? "Eject command outcome unknown: \(error.localizedDescription)"
                    : error.localizedDescription,
                mutationRequested: mutationRequested
            )
        }
    }

    nonisolated private func markEjectLaunching(generation: Int) throws {
        let ready = DispatchQueue.main.sync { [weak self] in
            guard let self, var eject = self.activeEject,
                  eject.generation == generation, self.isRunning, eject.phase == .preflight else {
                return false
            }
            eject.phase = .launching
            self.activeEject = eject
            return true
        }
        guard ready else {
            throw TroubleshooterError.cancelled
        }
    }

    nonisolated private func markEjectCommandStarted(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, var eject = self.activeEject,
                  eject.generation == generation, self.isRunning, eject.phase == .launching else {
                return
            }
            eject.phase = .inFlight
            self.activeEject = eject
        }
    }

    nonisolated private func markEjectPostconditionObserved(generation: Int) {
        DispatchQueue.main.sync { [weak self] in
            guard let self, var eject = self.activeEject,
                  eject.generation == generation, self.isRunning, eject.phase == .inFlight else {
                return
            }
            eject.phase = .postconditionObserved
            self.activeEject = eject
        }
    }

    nonisolated private func observeEjectedMedia(
        diskIdentifier: String,
        expectedRegistryEntryID: UInt64,
        runner: CommandRunner
    ) -> SelectedMediaPresence {
        postCollectionStep("IOKit: verify original IOMedia for /dev/\(diskIdentifier) after eject")
        do {
            return try TransportScanner(runner: runner).selectedMediaPresence(
                diskIdentifier: diskIdentifier,
                expectedRegistryEntryID: expectedRegistryEntryID
            )
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    nonisolated private func postEjectObservation(_ presence: SelectedMediaPresence, devicePath: String) {
        switch presence {
        case .absent:
            postLog("POSTCONDITION OBSERVED: the original whole-disk IOMedia is absent from \(devicePath).\n")
        case .same:
            postLog("POSTCONDITION OBSERVED: the original whole-disk IOMedia remains active.\n")
        case .replaced:
            postLog("POSTCONDITION UNKNOWN: \(devicePath) now names different whole-disk media; the original device may have disappeared or been replaced.\n")
        case let .unavailable(reason):
            postLog("POSTCONDITION UNKNOWN: could not verify original whole-disk media: \(reason)\n")
        }
    }

    nonisolated private func postEjectCompletion(
        generation: Int,
        outcome: StorageActionOutcome?,
        message: String,
        mutationRequested: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.completeEject(generation: generation, outcome: outcome, message: message, mutationRequested: mutationRequested)
        }
    }

    private func completeEject(
        generation: Int,
        outcome: StorageActionOutcome?,
        message: String,
        mutationRequested: Bool
    ) {
        guard let eject = activeEject, eject.generation == generation else {
            return
        }
        activeEject = nil
        let finalOutcome = completedEjectOutcome(outcome: outcome, phase: eject.phase, commandLaunched: mutationRequested)
        switch finalOutcome {
        case .success:
            appendLog("\nRESULT: SUCCESS — \(message)\n")
            finish(message, color: .systemGreen)
        case .failed:
            appendLog("\nRESULT: FAILED — \(message)\n")
            finish(message, color: .systemRed)
        case .unverified:
            let reason = eject.phase == .stopped ? "Stop was requested during eject; verify the original disk state" : message
            appendLog("\nRESULT: UNVERIFIED — \(reason). Check the disk in Disk Utility before another action.\n")
            finish("Eject outcome unverified — check Disk Utility", color: .systemOrange)
        case nil:
            appendLog("\nRESULT: CANCELLED — \(message)\n")
            finish("Cancelled", color: .systemOrange)
        }
    }

    @objc private func copyLog() {
        let report = reportForSharing()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        setStatus("Report copied to the clipboard", color: .systemGreen)
    }

    @objc private func saveReport() {
        guard let window else {
            setStatus("Report save failed: the application window is unavailable", color: .systemRed)
            appendLog("REPORT SAVE FAILED: the application window is unavailable.\n")
            return
        }
        let report = reportForSharing()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "volume-mount-report-\(formatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            guard let destination = panel.url else {
                self.setStatus("Report save failed: the save dialog returned no destination", color: .systemRed)
                self.appendLog("REPORT SAVE FAILED: the save dialog returned no destination. Choose a writable folder and try again.\n")
                return
            }
            do {
                try report.write(to: destination, atomically: true, encoding: .utf8)
                self.setStatus("Report saved to \(destination.path)", color: .systemGreen)
            } catch {
                self.setStatus("Report save failed: \(error.localizedDescription)", color: .systemRed)
                self.appendLog("REPORT SAVE FAILED: \(error.localizedDescription)\n")
            }
        }
    }

    private func reportForSharing() -> String {
        guard redactCheckbox?.state == .on else {
            let header = "Privacy redaction: disabled\n\n"
            return boundedSharedReport(header + completeLog.rendered, header: header)
        }
        let header = "Privacy redaction: enabled\n\n"
        let redacted = privacyRedactedReport(completeLog.rendered, userName: NSUserName())
        return boundedSharedReport(redacted, header: header)
    }

    @objc private func showUnlockerInFinder() {
        guard let mountPoint = nonEmpty(trackedUnlocker?.mountPoint) else {
            setStatus("The unlocker volume is not mounted", color: .systemRed)
            appendLog("UNLOCKER FINDER ACTION FAILED: no mounted unlocker path is available.\n")
            return
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: mountPoint, isDirectory: &isDirectory), isDirectory.boolValue else {
            setStatus("The unlocker volume is no longer available", color: .systemRed)
            appendLog("UNLOCKER FINDER ACTION FAILED: \(mountPoint) is no longer a mounted directory.\n")
            return
        }
        let opened = NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint, isDirectory: true))
        guard opened else {
            setStatus("Finder could not reveal the unlocker volume", color: .systemRed)
            appendLog("UNLOCKER FINDER ACTION FAILED: Finder rejected \(mountPoint).\n")
            return
        }
        setStatus("Unlocker volume shown in Finder", color: .systemGreen)
        appendLog("UNLOCKER FINDER ACTION: revealed \(mountPoint). No unlocker application was launched and no credentials were collected.\n")
    }

    @objc private func revealVolumes() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Volumes", isDirectory: true))
    }

    nonisolated private func performInspection(
        volume: ExternalVolume,
        disk: ExternalDisk,
        runner: CommandRunner?
    ) {
        guard let runner else {
            finishFailure("Command runner was unavailable")
            return
        }

        postOperationHeader(action: "Inspect", volume: volume, disk: disk)
        do {
            _ = try collectInspectionEvidence(volume: volume, disk: disk, runner: runner)
            try appendDiskArbitrationErrors(volume: volume, runner: runner)
            finishSuccess("Inspection complete for \(volume.name)")
        } catch TroubleshooterError.cancelled {
            finishCancelled()
        } catch let error as TroubleshooterError {
            postLog("\nFATAL: \(error.localizedDescription)\n")
            finishFailure(error.localizedDescription)
        } catch {
            postLog("\nFATAL: Unexpected execution error: \(error.localizedDescription)\n")
            finishFailure("Unexpected execution error: \(error.localizedDescription)")
        }
    }

    nonisolated private func performReadOnlyMount(
        volume: ExternalVolume,
        disk: ExternalDisk,
        runner: CommandRunner?
    ) {
        guard let runner else {
            finishFailure("Command runner was unavailable")
            return
        }

        postOperationHeader(action: "Mount Read-Only", volume: volume, disk: disk)
        var mutationRequested = false
        do {
            _ = try collectInspectionEvidence(volume: volume, disk: disk, runner: runner)
            let currentVolume = try validatedSelectedVolume(volume: volume, disk: disk, runner: runner)
            guard currentVolume.isLocked != true else {
                postLog(guidedFailureExplanation(exitStatus: 1, output: "volume locked", volume: volume) + "\n")
                appendOptionalDiskArbitrationErrors(volume: volume, runner: runner)
                finishFailure("Selected volume is encrypted and locked")
                return
            }

            guard currentVolume.mountPoint == volume.mountPoint, currentVolume.isWritable == volume.isWritable else {
                throw TroubleshooterError.selectedStorageChanged(reason: "the selected volume's mount or writable state changed before the read-only request")
            }
            if nonEmpty(currentVolume.mountPoint) != nil, currentVolume.isWritable == true {
                let unmount = try runLogged(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["unmount", "/dev/\(volume.identifier)"],
                    runner: runner,
                    onLaunch: { mutationRequested = true }
                )
                guard unmount.exitStatus == 0 else {
                    postLog(guidedFailureExplanation(exitStatus: unmount.exitStatus, output: unmount.output, volume: volume) + "\n")
                    let postcondition = observeSelectedStorage(volume: volume, disk: disk, runner: runner)
                    postStorageObservation(postcondition)
                    let result = unmountOutcome(exitStatus: unmount.exitStatus, observation: postcondition)
                    appendOptionalDiskArbitrationErrors(volume: volume, runner: runner)
                    finishStorageAction(StorageActionResult(
                        outcome: result.outcome,
                        message: result.message + "; read-only mount was not attempted"
                    ))
                    return
                }
                postLog("INTERMEDIATE RESULT: unmount command completed; read-only mount has not yet been verified.\n")
            }

            let unmountedVolume = try validatedSelectedVolume(volume: volume, disk: disk, runner: runner)
            guard nonEmpty(unmountedVolume.mountPoint) == nil else {
                postStorageObservation(.verified(unmountedVolume))
                finishUnverified("The selected volume was still mounted before the read-only mount request")
                return
            }
            let outcome = try runMountRequest(
                volume: volume,
                disk: disk,
                arguments: ["mount", "readOnly", "/dev/\(volume.identifier)"],
                runner: runner,
                onLaunch: { mutationRequested = true }
            )
            postStorageObservation(outcome.postcondition)
            if outcome.mountResult.exitStatus != 0 {
                postLog(guidedFailureExplanation(exitStatus: outcome.mountResult.exitStatus, output: outcome.mountResult.output, volume: volume) + "\n")
            }
            let result = readOnlyMountOutcome(exitStatus: outcome.mountResult.exitStatus, observation: outcome.postcondition)
            appendOptionalDiskArbitrationErrors(volume: volume, runner: runner)
            finishStorageAction(result)
        } catch TroubleshooterError.cancelled {
            if mutationRequested {
                finishUnverified("Stopped after a storage command launched; verify the current volume state")
            } else {
                finishCancelled()
            }
        } catch let error as TroubleshooterError {
            postLog("\nFATAL: \(error.localizedDescription)\n")
            if mutationRequested {
                finishUnverified("Storage command outcome unknown: \(error.localizedDescription)")
            } else {
                finishFailure(error.localizedDescription)
            }
        } catch {
            postLog("\nFATAL: Unexpected execution error: \(error.localizedDescription)\n")
            if mutationRequested {
                finishUnverified("Storage command outcome unknown: \(error.localizedDescription)")
            } else {
                finishFailure("Unexpected execution error: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private func performNormalMount(
        volume: ExternalVolume,
        disk: ExternalDisk,
        runner: CommandRunner?
    ) {
        guard let runner else {
            finishFailure("Command runner was unavailable")
            return
        }

        postOperationHeader(action: "Mount Normally", volume: volume, disk: disk)
        var mutationRequested = false
        do {
            _ = try collectInspectionEvidence(volume: volume, disk: disk, runner: runner)
            let currentVolume = try validatedSelectedVolume(volume: volume, disk: disk, runner: runner)
            guard currentVolume.isLocked != true else {
                postLog(guidedFailureExplanation(exitStatus: 1, output: "volume locked", volume: volume) + "\n")
                appendOptionalDiskArbitrationErrors(volume: volume, runner: runner)
                finishFailure("Selected volume is encrypted and locked")
                return
            }

            let outcome = try runMountRequest(
                volume: volume,
                disk: disk,
                arguments: ["mount", "/dev/\(volume.identifier)"],
                runner: runner,
                onLaunch: { mutationRequested = true }
            )
            postStorageObservation(outcome.postcondition)
            if outcome.mountResult.exitStatus != 0 {
                postLog(guidedFailureExplanation(exitStatus: outcome.mountResult.exitStatus, output: outcome.mountResult.output, volume: volume) + "\n")
            }
            let result = normalMountOutcome(exitStatus: outcome.mountResult.exitStatus, observation: outcome.postcondition)
            appendOptionalDiskArbitrationErrors(volume: volume, runner: runner)
            finishStorageAction(result)
        } catch TroubleshooterError.cancelled {
            if mutationRequested {
                finishUnverified("Stopped after a mount command launched; verify the current volume state")
            } else {
                finishCancelled()
            }
        } catch let error as TroubleshooterError {
            postLog("\nFATAL: \(error.localizedDescription)\n")
            if mutationRequested {
                finishUnverified("Mount command outcome unknown: \(error.localizedDescription)")
            } else {
                finishFailure(error.localizedDescription)
            }
        } catch {
            postLog("\nFATAL: Unexpected execution error: \(error.localizedDescription)\n")
            if mutationRequested {
                finishUnverified("Mount command outcome unknown: \(error.localizedDescription)")
            } else {
                finishFailure("Unexpected execution error: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private func performUnmount(
        volume: ExternalVolume,
        disk: ExternalDisk,
        runner: CommandRunner?
    ) {
        guard let runner else {
            finishFailure("Command runner was unavailable")
            return
        }

        postOperationHeader(action: "Unmount Volume", volume: volume, disk: disk)
        var mutationRequested = false
        do {
            _ = try validatedSelectedVolume(volume: volume, disk: disk, runner: runner)
            let commandResult = try runLogged(
                executable: "/usr/sbin/diskutil",
                arguments: ["unmount", "/dev/\(volume.identifier)"],
                runner: runner,
                onLaunch: { mutationRequested = true }
            )
            let postcondition = observeSelectedStorage(volume: volume, disk: disk, runner: runner)
            postStorageObservation(postcondition)
            if commandResult.exitStatus != 0 {
                postLog(guidedFailureExplanation(exitStatus: commandResult.exitStatus, output: commandResult.output, volume: volume) + "\n")
            }
            let result = unmountOutcome(exitStatus: commandResult.exitStatus, observation: postcondition)
            appendOptionalDiskArbitrationErrors(volume: volume, runner: runner)
            finishStorageAction(result)
        } catch TroubleshooterError.cancelled {
            if mutationRequested {
                finishUnverified("Stopped after an unmount command launched; verify the current volume state")
            } else {
                finishCancelled()
            }
        } catch let error as TroubleshooterError {
            postLog("\nFATAL: \(error.localizedDescription)\n")
            if mutationRequested {
                finishUnverified("Unmount command outcome unknown: \(error.localizedDescription)")
            } else {
                finishFailure(error.localizedDescription)
            }
        } catch {
            postLog("\nFATAL: Unexpected execution error: \(error.localizedDescription)\n")
            if mutationRequested {
                finishUnverified("Unmount command outcome unknown: \(error.localizedDescription)")
            } else {
                finishFailure("Unexpected execution error: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private func postOperationHeader(
        action: String,
        volume: ExternalVolume,
        disk: ExternalDisk
    ) {
        postLog("Volume Mount Troubleshooter\n")
        postLog("Started: \(ISO8601DateFormatter().string(from: Date()))\n")
        postLog("Selected: \(volume.name) (/dev/\(volume.identifier)) on /dev/\(disk.identifier)\n")
        postLog("Explicit action: \(action)\n")
        postLog("Safety: no repair, erase, format, force-unmount, or credential commands.\n\n")
    }

    nonisolated private func collectInspectionEvidence(
        volume: ExternalVolume,
        disk: ExternalDisk,
        runner: CommandRunner
    ) throws -> ExternalVolume {
        let evidence = try DiskScanner(runner: runner).currentSelectedStorageEvidence(
            volume: volume,
            disk: disk,
            onCommand: postCollectionStep
        )
        let currentVolume = evidence.state.volume
        let smartStatus = nonEmpty(evidence.state.wholeDiskInfo.smartStatus) ?? "Unavailable"
        postLog(selectedStorageReport(
            volume: currentVolume,
            diskInfo: evidence.state.wholeDiskInfo,
            expandedSMART: evidence.expandedSMART
        ))
        postLog(physicalTransportReport(
            transport: evidence.transport,
            selectedIdentifier: currentVolume.identifier,
            physicalStoreIdentifiers: currentVolume.physicalStoreIdentifiers,
            smartStatus: smartStatus
        ))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectedVolume()?.identifier == volume.identifier else {
                return
            }
            self.connectionPathLabel?.stringValue = physicalConnectionSummary(evidence.transport)
            self.connectionPathLabel?.toolTip = physicalTransportReport(
                transport: evidence.transport,
                selectedIdentifier: currentVolume.identifier,
                physicalStoreIdentifiers: currentVolume.physicalStoreIdentifiers,
                smartStatus: smartStatus
            )
        }
        return currentVolume
    }

    nonisolated private func postCollectionStep(_ step: String) {
        postLog(step.hasPrefix("/") ? "$ \(step)\n" : "\(step)\n")
    }

    nonisolated private func validatedSelectedVolume(
        volume: ExternalVolume,
        disk: ExternalDisk,
        runner: CommandRunner
    ) throws -> ExternalVolume {
        try DiskScanner(runner: runner).validatedSelectedStorage(
            volume: volume,
            disk: disk,
            onCommand: postCollectionStep
        ).volume
    }

    nonisolated private func runMountRequest(
        volume: ExternalVolume,
        disk: ExternalDisk,
        arguments: [String],
        runner: CommandRunner,
        onLaunch: () -> Void
    ) throws -> MountRequestOutcome {
        let mountResult = try runLogged(
            executable: "/usr/sbin/diskutil",
            arguments: arguments,
            runner: runner,
            onLaunch: onLaunch
        )
        return MountRequestOutcome(
            mountResult: mountResult,
            postcondition: observeSelectedStorage(volume: volume, disk: disk, runner: runner)
        )
    }

    nonisolated private func observeSelectedStorage(
        volume: ExternalVolume,
        disk: ExternalDisk,
        runner: CommandRunner
    ) -> StorageStateObservation {
        do {
            return .verified(try validatedSelectedVolume(volume: volume, disk: disk, runner: runner))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    nonisolated private func appendOptionalDiskArbitrationErrors(volume: ExternalVolume, runner: CommandRunner) {
        let coverage = collectDiagnosticCoverage {
            try appendDiskArbitrationErrors(volume: volume, runner: runner)
        }
        if case let .unavailable(reason) = coverage {
            postLog("DIAGNOSTIC COVERAGE UNAVAILABLE: \(reason)\n")
        }
    }

    nonisolated private func postStorageObservation(_ observation: StorageStateObservation) {
        switch observation {
        case let .verified(current):
            if let mountPoint = nonEmpty(current.mountPoint) {
                let writable = current.isWritable.map { $0 ? "writable" : "read-only" } ?? "writable state unknown"
                postLog("POSTCONDITION OBSERVED: /dev/\(current.identifier) is mounted at \(mountPoint) (\(writable)); selected media identity verified.\n")
            } else {
                postLog("POSTCONDITION OBSERVED: /dev/\(current.identifier) is unmounted; selected media identity verified.\n")
            }
        case let .unavailable(reason):
            postLog("POSTCONDITION UNKNOWN: \(reason)\n")
        }
    }

    nonisolated private func appendDiskArbitrationErrors(volume: ExternalVolume, runner: CommandRunner) throws {
        let selectedPattern = ".*\\\\b\(volume.identifier)\\\\b.*"
        let wholePattern = ".*\\\\b\(volume.wholeDiskIdentifier)(s[0-9]+)*\\\\b.*"
        let predicate = "process == \"diskarbitrationd\" AND (messageType == error OR messageType == fault) AND (eventMessage MATCHES[c] \"\(selectedPattern)\" OR eventMessage MATCHES[c] \"\(wholePattern)\")"
        let result = try runCaptured(
            executable: "/usr/bin/log",
            arguments: [
                "show",
                "--last",
                "15m",
                "--style",
                "compact",
                "--predicate",
                predicate
            ],
            reason: "Selected-storage Disk Arbitration log",
            runner: runner
        )
        guard result.exitStatus == 0 else {
            throw TroubleshooterError.commandFailed(
                command: renderedCommand(executable: "/usr/bin/log", arguments: ["show", "--last", "15m", "--style", "compact", "--predicate", predicate]),
                exitStatus: result.exitStatus,
                output: "Selected-storage log coverage failed.\n\(result.output)"
            )
        }
        let logBody = diskArbitrationLogBody(result.output)
        if logBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            postLog("Disk Arbitration: no error or fault entries naming these current disk identifiers in the last 15 minutes.\n")
        } else {
            postLog(logBody)
            if !logBody.hasSuffix("\n") { postLog("\n") }
        }
        postLog("Log coverage: earlier entries may refer to a different device that used the same disk number; entries without these identifiers cannot be correlated.\n\n")
    }

    nonisolated private func runLogged(
        executable: String,
        arguments: [String],
        runner: CommandRunner
    ) throws -> CommandResult {
        try runLogged(executable: executable, arguments: arguments, runner: runner, onLaunch: {})
    }

    nonisolated private func runLogged(
        executable: String,
        arguments: [String],
        runner: CommandRunner,
        onLaunch: () -> Void
    ) throws -> CommandResult {
        let command = renderedCommand(executable: executable, arguments: arguments)
        postLog("$ \(command)\n")
        var lastOutputEndedInNewline = true
        let result: CommandResult
        do {
            result = try runner.run(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: 30,
                onLaunch: onLaunch,
                onOutput: { [weak self] chunk in
                    lastOutputEndedInNewline = chunk.hasSuffix("\n")
                    self?.postCommandOutput(chunk)
                }
            )
        } catch {
            if !lastOutputEndedInNewline { postCommandOutputEnd() }
            throw error
        }
        if !result.output.hasSuffix("\n") {
            postCommandOutputEnd()
        }
        postLog("[exit status: \(result.exitStatus)]\n\n")
        return result
    }

    nonisolated private func runCaptured(
        executable: String,
        arguments: [String],
        reason: String,
        runner: CommandRunner
    ) throws -> CommandResult {
        let command = renderedCommand(executable: executable, arguments: arguments)
        postLog("$ \(command)\n")
        let result = try runner.run(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: 30
        ) { _ in }
        if result.exitStatus == 0 {
            postLog("[\(reason)]\n")
        } else {
            postLog(result.output)
            if !result.output.hasSuffix("\n") { postLog("\n") }
        }
        postLog("[exit status: \(result.exitStatus)]\n\n")
        return result
    }

    nonisolated private func postLog(_ text: String) {
        logPostLock.lock()
        defer { logPostLock.unlock() }
        let pending = pendingLog.snapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !pending.isEmpty { self.appendOutput(pending) }
            self.appendLog(text)
        }
    }

    nonisolated private func postCommandOutput(_ text: String) {
        logPostLock.lock()
        defer { logPostLock.unlock() }
        guard let generation = pendingLog.enqueue(text) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let pending = self.pendingLog.take(generation: generation), !pending.isEmpty {
                self.appendOutput(pending)
            }
        }
    }

    nonisolated private func postCommandOutputEnd() {
        logPostLock.lock()
        defer { logPostLock.unlock() }
        let pending = pendingLog.snapshot()
        pendingLog.endOutput()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !pending.isEmpty { self.appendOutput(pending) }
            self.appendOutput("\n")
        }
    }

    nonisolated private func finishStorageAction(_ result: StorageActionResult) {
        switch result.outcome {
        case .success:
            finishSuccess(result.message)
        case .failed:
            finishFailure(result.message)
        case .unverified:
            finishUnverified(result.message)
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

    nonisolated private func finishUnverified(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog("\nRESULT: UNVERIFIED — \(message). Check the selected device in Disk Utility before another action.\n")
            self?.finish("Outcome unverified — check Disk Utility", color: .systemOrange)
        }
    }

    nonisolated private func finishCancelled() {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog("\nRESULT: CANCELLED — operation stopped\n")
            self?.finish("Cancelled", color: .systemOrange)
        }
    }

    private func appendLog(_ text: String) {
        displayLog(completeLog.appendingEntry(text, maximumBytes: maximumReportBytes), appended: text)
    }

    private func appendOutput(_ text: String) {
        displayLog(completeLog.appending(text, maximumBytes: maximumReportBytes), appended: text)
    }

    private func displayLog(_ updated: BoundedDiagnosticLog, appended text: String) {
        completeLog = updated
        guard let textView else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        if updated.omittedEarlierContent {
            textView.textStorage?.setAttributedString(NSAttributedString(string: updated.rendered, attributes: attributes))
        } else {
            textView.textStorage?.append(NSAttributedString(string: text, attributes: attributes))
        }
        textView.scrollToEndOfDocument(nil)
    }

    private func finish(_ message: String, color: NSColor) {
        isRunning = false
        setControlsForRunningState(false)
        setStatus(message, color: color)
        postRefreshStatus = (message: message, color: color)
        refreshVolumes(automatic: true)
    }

    private func setControlsForRunningState(_ running: Bool) {
        let availability = volumeActionAvailability(for: selectedVolume())
        let actionsEnabled = !running && !isRefreshing
        inspectButton?.isEnabled = actionsEnabled && availability.inspect
        mountReadOnlyButton?.isEnabled = actionsEnabled && availability.mountReadOnly
        mountNormallyButton?.isEnabled = actionsEnabled && availability.mountNormally
        unmountButton?.isEnabled = actionsEnabled && availability.unmountVolume
        stopButton?.isEnabled = running || isRefreshing
        refreshButton?.isEnabled = !running && !isRefreshing
        ejectButton?.isEnabled = actionsEnabled && availability.safeEjectDisk
        let hasUnlockerMountPoint = nonEmpty(trackedUnlocker?.mountPoint) != nil
        showUnlockerButton?.isEnabled = !running && !isRefreshing && hasUnlockerMountPoint
        volumePopup?.isEnabled = !running && !isRefreshing && !snapshot.volumes.isEmpty
        copyButton?.isEnabled = !running && !completeLog.isEmpty
        saveButton?.isEnabled = !running && !completeLog.isEmpty
        revealButton?.isEnabled = !running
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
    }
}
