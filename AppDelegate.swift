import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runner = CommandRunner()
    private let scanRunner = CommandRunner()
    private let unlockRetryLimit = 5
    private let unlockRetryDelay: TimeInterval = 2
    private var diskMonitor: DiskEventMonitor?
    private var refreshWorkItem: DispatchWorkItem?
    private var unlockRetryWorkItem: DispatchWorkItem?
    private var snapshot = DiskSnapshot(disks: [], unlockers: [])
    private var window: NSWindow?
    private var textView: NSTextView?
    private var statusLabel: NSTextField?
    private var volumePopup: NSPopUpButton?
    private var volumeDetailLabel: NSTextField?
    private var unlockProgressLabel: NSTextField?
    private var readOnlyCheckbox: NSButton?
    private var redactCheckbox: NSButton?
    private var startButton: NSButton?
    private var stopButton: NSButton?
    private var refreshButton: NSButton?
    private var ejectButton: NSButton?
    private var showUnlockerButton: NSButton?
    private var copyButton: NSButton?
    private var saveButton: NSButton?
    private var revealButton: NSButton?
    private var completeLog = ""
    private var isRunning = false
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
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Volume Mount Troubleshooter"
        window.isRestorable = false
        window.center()
        window.minSize = NSSize(width: 820, height: 600)

        let rootView = NSView()
        window.contentView = rootView

        let titleLabel = NSTextField(labelWithString: "External Volume Mount Troubleshooter")
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "Select one external volume, inspect attachment and filesystem evidence, then request a normal or read-only mount. No erase, format, repair, or credential collection."
        )
        subtitleLabel.textColor = .secondaryLabelColor

        let selectorLabel = NSTextField(labelWithString: "External volume:")
        selectorLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let volumePopup = NSPopUpButton()
        volumePopup.addItem(withTitle: "Scanning for external volumes…")
        volumePopup.isEnabled = false
        volumePopup.target = self
        volumePopup.action = #selector(volumeSelectionChanged)
        self.volumePopup = volumePopup

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed))
        refreshButton.bezelStyle = .rounded
        self.refreshButton = refreshButton

        let selectorStack = NSStackView(views: [selectorLabel, volumePopup, refreshButton])
        selectorStack.orientation = .horizontal
        selectorStack.spacing = 8
        selectorStack.alignment = .centerY
        volumePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let volumeDetailLabel = NSTextField(wrappingLabelWithString: "Scanning for external volumes…")
        volumeDetailLabel.textColor = .secondaryLabelColor
        volumeDetailLabel.font = NSFont.systemFont(ofSize: 12)
        self.volumeDetailLabel = volumeDetailLabel

        let unlockProgressLabel = NSTextField(wrappingLabelWithString: "")
        unlockProgressLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        unlockProgressLabel.textColor = .systemOrange
        unlockProgressLabel.isHidden = true
        self.unlockProgressLabel = unlockProgressLabel

        let readOnlyCheckbox = NSButton(checkboxWithTitle: "Mount read-only", target: self, action: nil)
        readOnlyCheckbox.state = .on
        self.readOnlyCheckbox = readOnlyCheckbox

        let redactCheckbox = NSButton(checkboxWithTitle: "Redact shared reports", target: self, action: nil)
        redactCheckbox.state = .on
        self.redactCheckbox = redactCheckbox

        let optionStack = NSStackView(views: [readOnlyCheckbox, redactCheckbox])
        optionStack.orientation = .horizontal
        optionStack.spacing = 20
        optionStack.alignment = .centerY

        let statusLabel = NSTextField(labelWithString: "Scanning…")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        self.statusLabel = statusLabel

        let startButton = NSButton(title: "Start", target: self, action: #selector(startTroubleshooting))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.isEnabled = false
        self.startButton = startButton

        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stopTroubleshooting))
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false
        self.stopButton = stopButton

        let ejectButton = NSButton(title: "Safe Eject…", target: self, action: #selector(ejectSelectedDisk))
        ejectButton.bezelStyle = .rounded
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
        copyButton.isEnabled = false
        self.copyButton = copyButton

        let saveButton = NSButton(title: "Save Report…", target: self, action: #selector(saveReport))
        saveButton.bezelStyle = .rounded
        saveButton.isEnabled = false
        self.saveButton = saveButton

        let revealButton = NSButton(title: "Show Volumes", target: self, action: #selector(revealVolumes))
        revealButton.bezelStyle = .rounded
        self.revealButton = revealButton

        let buttonStack = NSStackView(views: [
            startButton,
            stopButton,
            ejectButton,
            showUnlockerButton,
            copyButton,
            saveButton,
            revealButton
        ])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(calibratedRed: 0.78, green: 0.94, blue: 0.80, alpha: 1)
        textView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        self.textView = textView

        let contentStack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            selectorStack,
            volumeDetailLabel,
            unlockProgressLabel,
            optionStack,
            statusLabel,
            buttonStack,
            scrollView
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 9
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(contentStack)

        [
            titleLabel,
            subtitleLabel,
            selectorStack,
            volumeDetailLabel,
            unlockProgressLabel,
            optionStack,
            statusLabel,
            buttonStack,
            scrollView
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20),
            titleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            selectorStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            volumeDetailLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            unlockProgressLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            optionStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttonStack.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        window.makeKeyAndOrderFront(nil)
        self.window = window
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
        let selectedWasRemoved = selectedIdentifier.map {
            deviceIdentifier($0, isSameAsOrDescendantOf: identifier)
        } ?? false
        let scanWasRunning = isRefreshing
        let updatedSnapshot = snapshot.removingDevice(identifier: identifier)
        let trackedUnlockerWasRemoved = trackedUnlocker.map { unlocker in
            !updatedSnapshot.unlockers.contains(unlocker)
        } ?? false
        if selectedWasRemoved {
            selectionRequiresUserChoice = true
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
        setStatus("Disconnected /dev/\(identifier) — stale selection cleared", color: .systemOrange)
        appendLog("AUTO-DETECT: /dev/\(identifier) disappeared; its stale selector entry was removed immediately.\n")

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
        refreshButton?.isEnabled = false
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
                    self.applySnapshot(
                        newSnapshot,
                        selectedIdentifier: selectedIdentifier,
                        previousIdentifiers: previousIdentifiers,
                        automatic: automatic
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    guard self.scanGeneration == currentScanGeneration else {
                        self.finishSupersededScan()
                        return
                    }
                    self.isRefreshing = false
                    self.refreshButton?.isEnabled = true
                    self.setStatus("Volume scan failed: \(error.localizedDescription)", color: .systemRed)
                    self.appendLog("SCAN FAILURE: \(error.localizedDescription)\n")
                    self.updateUnlockTransition()
                    self.setControlsForRunningState(self.isRunning)
                    self.runPendingAutomaticRefreshIfNeeded()
                }
            }
        }
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
        }
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
        let encryptionState = volume.isLocked ? "encrypted and locked" : (volume.isEncrypted ? "encrypted and unlocked" : "not encrypted")
        let role = volume.role.map { " • APFS role: \($0)" } ?? ""
        volumeDetailLabel?.stringValue = "\(mountState) • \(encryptionState) • \(formattedByteCount(volume.size)) • \(disk.busProtocol) • SMART: \(disk.smartStatus)\(role)"
        setStatus("Ready — press Start to diagnose and mount the selected volume", color: .labelColor)
    }

    private func selectedVolume() -> ExternalVolume? {
        guard let index = volumePopup?.selectedItem?.tag, snapshot.volumes.indices.contains(index) else {
            return nil
        }
        return snapshot.volumes[index]
    }

    @objc private func startTroubleshooting() {
        guard !isRunning, let volume = selectedVolume(), let disk = snapshot.disk(containing: volume) else {
            return
        }

        let readOnly = readOnlyCheckbox?.state == .on
        let requiresReadOnlyRemount = readOnly && volume.mountPoint != nil && volume.isWritable
        if requiresReadOnlyRemount && !confirmReadOnlyRemount(volume: volume) {
            return
        }

        isRunning = true
        completeLog = ""
        textView?.string = ""
        runner.reset()
        setControlsForRunningState(true)
        setStatus("Running diagnostics for \(volume.name)…", color: .systemBlue)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performTroubleshooting(
                volume: volume,
                disk: disk,
                readOnly: readOnly,
                requiresReadOnlyRemount: requiresReadOnlyRemount,
                runner: self?.runner
            )
        }
    }

    private func confirmReadOnlyRemount(volume: ExternalVolume) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remount \(volume.name) read-only?"
        alert.informativeText = "The selected volume is currently mounted writable. macOS must unmount only this volume before mounting it read-only. Close files using it first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unmount and Remount")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func stopTroubleshooting() {
        runner.cancel()
        appendLog("\nStop requested. Terminating the active command…\n")
        setStatus("Stopping…", color: .systemOrange)
    }

    @objc private func ejectSelectedDisk() {
        guard !isRunning, let volume = selectedVolume() else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Safely eject /dev/\(volume.wholeDiskIdentifier)?"
        alert.informativeText = "This ejects the whole external physical disk, including any sibling volumes. Close files using them first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Safe Eject")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isRunning = true
        completeLog = ""
        textView?.string = ""
        runner.reset()
        setControlsForRunningState(true)
        setStatus("Ejecting external disk…", color: .systemBlue)
        let devicePath = "/dev/\(volume.wholeDiskIdentifier)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            do {
                let result = try self.runLogged(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["eject", devicePath],
                    runner: self.runner
                )
                if result.exitStatus == 0 {
                    self.finishSuccess("Safely ejected \(devicePath)")
                } else {
                    self.postLog(guidedFailureExplanation(exitStatus: result.exitStatus, output: result.output, volume: volume) + "\n")
                    self.finishFailure("Eject failed for \(devicePath)")
                }
            } catch TroubleshooterError.cancelled {
                self.finishCancelled()
            } catch {
                self.postLog("FATAL: \(error.localizedDescription)\n")
                self.finishFailure(error.localizedDescription)
            }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "volume-mount-report-\(formatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        do {
            try reportForSharing().write(to: destination, atomically: true, encoding: .utf8)
            setStatus("Report saved to \(destination.path)", color: .systemGreen)
        } catch {
            setStatus("Report save failed: \(error.localizedDescription)", color: .systemRed)
        }
    }

    private func reportForSharing() -> String {
        guard redactCheckbox?.state == .on else {
            return "Privacy redaction: disabled\n\n\(completeLog)"
        }
        return privacyRedactedReport(completeLog, userName: NSUserName())
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

    nonisolated private func performTroubleshooting(
        volume: ExternalVolume,
        disk: ExternalDisk,
        readOnly: Bool,
        requiresReadOnlyRemount: Bool,
        runner: CommandRunner?
    ) {
        guard let runner else {
            finishFailure("Command runner was unavailable")
            return
        }

        postLog("Volume Mount Troubleshooter\n")
        postLog("Started: \(ISO8601DateFormatter().string(from: Date()))\n")
        postLog("Selected: \(volume.name) (/dev/\(volume.identifier)) on /dev/\(disk.identifier)\n")
        postLog("Requested mode: \(readOnly ? "read-only" : "normal")\n")
        postLog("Safety: no repair, erase, format, or credential commands.\n\n")

        do {
            let profiler = try runLogged(
                executable: "/usr/sbin/system_profiler",
                arguments: ["SPUSBDataType", "SPThunderboltDataType", "-detailLevel", "mini"],
                runner: runner
            )
            if profiler.exitStatus != 0 {
                postLog("WARNING: System Profiler failed; diskutil remains the authoritative storage inventory.\n\n")
            }

            _ = try runLogged(
                executable: "/usr/sbin/diskutil",
                arguments: ["list", "external", "physical"],
                runner: runner
            )
            _ = try runLogged(
                executable: "/usr/sbin/diskutil",
                arguments: ["info", "/dev/\(disk.identifier)"],
                runner: runner
            )
            postLog("DEVICE HEALTH: bus=\(disk.busProtocol), SMART=\(disk.smartStatus), size=\(formattedByteCount(disk.size))\n\n")

            let ioreg = try runCaptured(
                executable: "/usr/sbin/ioreg",
                arguments: ["-p", "IOUSB", "-l", "-w0"],
                reason: "raw output omitted because it can contain hardware serial identifiers",
                runner: runner
            )
            if let speed = usbLinkSpeedBitsPerSecond(from: ioreg.output, productName: disk.name) {
                postLog("USB CONNECTION SPEED: \(formattedLinkSpeed(speed)) for \(disk.name)\n\n")
            } else {
                postLog("USB CONNECTION SPEED: unavailable for \(disk.name); the device may use a path not exposed in the IOUSB plane.\n\n")
            }

            _ = try runLogged(
                executable: "/usr/sbin/diskutil",
                arguments: ["info", "/dev/\(volume.identifier)"],
                runner: runner
            )
            let encryptionState = volume.isLocked ? "encrypted and locked" : (volume.isEncrypted ? "encrypted and unlocked" : "not encrypted")
            postLog("ENCRYPTION CHECK: \(encryptionState). No credentials were requested.\n\n")

            guard !volume.isLocked else {
                postLog(guidedFailureExplanation(exitStatus: 1, output: "volume locked", volume: volume) + "\n")
                try appendDiskArbitrationErrors(runner: runner)
                finishFailure("Selected volume is encrypted and locked")
                return
            }

            if requiresReadOnlyRemount {
                let unmount = try runLogged(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["unmount", "/dev/\(volume.identifier)"],
                    runner: runner
                )
                guard unmount.exitStatus == 0 else {
                    postLog(guidedFailureExplanation(exitStatus: unmount.exitStatus, output: unmount.output, volume: volume) + "\n")
                    try appendDiskArbitrationErrors(runner: runner)
                    finishFailure("Could not unmount the selected volume for read-only remount")
                    return
                }
            }

            let mountArguments = readOnly
                ? ["mount", "readOnly", "/dev/\(volume.identifier)"]
                : ["mount", "/dev/\(volume.identifier)"]
            let mountResult = try runLogged(
                executable: "/usr/sbin/diskutil",
                arguments: mountArguments,
                runner: runner
            )

            let verifyArguments = ["info", "-plist", "/dev/\(volume.identifier)"]
            let verification = try runCaptured(
                executable: "/usr/sbin/diskutil",
                arguments: verifyArguments,
                reason: "structured plist decoded for mount verification",
                runner: runner
            )
            guard verification.exitStatus == 0 else {
                postLog(guidedFailureExplanation(exitStatus: verification.exitStatus, output: verification.output, volume: volume) + "\n")
                try appendDiskArbitrationErrors(runner: runner)
                finishFailure("Could not verify /dev/\(volume.identifier) after the mount request")
                return
            }
            let currentInfo = try decodePropertyList(
                DiskInfoPropertyList.self,
                output: verification.output,
                command: renderedCommand(executable: "/usr/sbin/diskutil", arguments: verifyArguments)
            )
            try appendDiskArbitrationErrors(runner: runner)

            guard mountResult.exitStatus == 0 else {
                postLog(guidedFailureExplanation(exitStatus: mountResult.exitStatus, output: mountResult.output, volume: volume) + "\n")
                finishFailure("Mount failed for /dev/\(volume.identifier)")
                return
            }
            guard let mountPoint = nonEmpty(currentInfo.mountPoint) else {
                postLog(guidedFailureExplanation(exitStatus: 0, output: mountResult.output, volume: volume) + "\n")
                finishFailure("Mount command succeeded, but no mount point was verified")
                return
            }
            if readOnly, currentInfo.writableVolume == true {
                postLog("GUIDED EXPLANATION: macOS mounted the volume writable even though read-only was requested.\n")
                finishFailure("Read-only state was not verified at \(mountPoint)")
                return
            }

            postLog("VERIFIED MOUNT: \(mountPoint) (\(readOnly ? "read-only" : "normal"))\n")
            finishSuccess("Mounted \(volume.name) at \(mountPoint)")
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

    nonisolated private func appendDiskArbitrationErrors(runner: CommandRunner) throws {
        let result = try runLogged(
            executable: "/usr/bin/log",
            arguments: [
                "show",
                "--last",
                "15m",
                "--style",
                "compact",
                "--predicate",
                "process == \"diskarbitrationd\" AND (messageType == error OR messageType == fault)"
            ],
            runner: runner
        )
        if result.exitStatus == 0, result.output.split(separator: "\n").count <= 1 {
            postLog("DISK ARBITRATION LOG CHECK: no error or fault entries in the last 15 minutes.\n\n")
        }
    }

    nonisolated private func runLogged(
        executable: String,
        arguments: [String],
        runner: CommandRunner
    ) throws -> CommandResult {
        let command = renderedCommand(executable: executable, arguments: arguments)
        postLog("$ \(command)\n")
        let result = try runner.run(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: 30
        ) { [weak self] chunk in
            self?.postLog(chunk)
        }
        if !result.output.hasSuffix("\n") {
            postLog("\n")
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
        postLog("[\(reason)]\n")
        postLog("[exit status: \(result.exitStatus)]\n\n")
        return result
    }

    nonisolated private func postLog(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog(text)
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

    nonisolated private func finishCancelled() {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog("\nRESULT: CANCELLED by user\n")
            self?.finish("Cancelled", color: .systemOrange)
        }
    }

    private func appendLog(_ text: String) {
        completeLog.append(text)
        guard let textView else {
            return
        }
        textView.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.78, green: 0.94, blue: 0.80, alpha: 1)
        ]))
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
        let hasSelection = selectedVolume() != nil
        startButton?.isEnabled = !running && hasSelection && !isRefreshing
        stopButton?.isEnabled = running
        refreshButton?.isEnabled = !running && !isRefreshing
        ejectButton?.isEnabled = !running && hasSelection && !isRefreshing
        let hasUnlockerMountPoint = nonEmpty(trackedUnlocker?.mountPoint) != nil
        showUnlockerButton?.isEnabled = !running && !isRefreshing && hasUnlockerMountPoint
        volumePopup?.isEnabled = !running && !isRefreshing && !snapshot.volumes.isEmpty
        readOnlyCheckbox?.isEnabled = !running
        copyButton?.isEnabled = !running && !completeLog.isEmpty
        saveButton?.isEnabled = !running && !completeLog.isEmpty
        revealButton?.isEnabled = !running
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
    }
}
