import AppKit

@MainActor
extension AppViewModel {
    func prepareModalWindowPresentation() {
        // A menu-bar-only app is usually inactive (and can even be hidden) while its panel is
        // open. Without this the alert window can be created but never ordered in front, which
        // is exactly the "no dialog, app frozen" state users hit before.
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Above the status item panel (25) so an open menu can never cover the alert, but below
    /// the system menu levels. NSAlert resets its own level inside `runModal`, which is why the
    /// previous fix could not work: alerts are now presented by our own plain window instead.
    static var alertWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    }

    func configureModalWindow(_ window: NSWindow) {
        window.level = Self.alertWindowLevel
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.hidesOnDeactivate = false
    }

    /// Non-blocking replacement for `NSAlert.runModal()`.
    ///
    /// The old implementation parked the main thread inside a modal event loop. If the alert
    /// window was hidden behind the status panel (or ordered out by a stray click) the loop kept
    /// running with nothing on screen: the app looked frozen and any later alert nested inside
    /// the stuck session. This version never blocks — it shows a normal window and suspends the
    /// calling task until a button is pressed or the window closes.
    @discardableResult
    func presentAlert(
        style: NSAlert.Style,
        message: String,
        informative: String,
        buttons: [String],
        accessory: NSView? = nil,
        autoDismissAfter seconds: TimeInterval? = nil) async -> NSApplication.ModalResponse
    {
        self.prepareModalWindowPresentation()
        return await AlertWindowController.shared.present(
            style: style,
            message: message,
            informative: informative,
            buttons: buttons,
            accessory: accessory,
            level: Self.alertWindowLevel,
            autoDismissAfter: seconds)
    }
}

@MainActor
extension AppViewModel {
    func presentCoreFailureAlert(
        title: String,
        message: String,
        dedupeKey: String,
        style: NSAlert.Style = .warning)
    {
        let now = Date()
        if self.lastCoreFailureAlertKey == dedupeKey,
           let lastAt = self.lastCoreFailureAlertAt,
           now.timeIntervalSince(lastAt) < self.coreFailureAlertThrottleInterval
        {
            return
        }

        self.lastCoreFailureAlertKey = dedupeKey
        self.lastCoreFailureAlertAt = now

        // Resolve localized strings before entering the task: inside a `[weak self]` closure
        // `self` is optional, so instance members must be referenced as `self?.` there.
        let okTitle = self.tr("ui.action.ok")

        Task { [weak self] in
            _ = await self?.presentAlert(
                style: style,
                message: title,
                informative: message,
                buttons: [okTitle])
        }
    }

    func presentConfigValidationFailedAlert(fileName: String, details: String) {
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        var informativeParts = [tr("app.config.validation_failed.message", fileName)]
        if Self.validationFailureLooksGeoRelated(trimmedDetails) {
            informativeParts.append(tr("app.config.validation_failed.hint.geo"))
        }
        informativeParts.append(tr("app.config.validation_failed.hint.common"))
        let informative = informativeParts.joined(separator: "\n\n")

        let detailsText = trimmedDetails.isEmpty ? self.tr("ui.common.unknown") : trimmedDetails
        let accessory = Self.makeScrollableDetailsView(detailsText)

        Task { [weak self] in
            guard let self else { return }
            let response = await self.presentAlert(
                style: .critical,
                message: tr("app.config.validation_failed.title"),
                informative: informative,
                buttons: [tr("ui.action.ok"), tr("ui.action.copy_details")],
                accessory: accessory)

            if response == .alertSecondButtonReturn {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(trimmedDetails, forType: .string)
            }
        }
    }

    private static func validationFailureLooksGeoRelated(_ details: String) -> Bool {
        let lower = details.lowercased()
        let needles = [
            "geoip", "geosite", "mmdb", "geox-url", "geodata",
            "country.mmdb", "geosite.dat", "geoip.dat", ".metadb", "geolite", "asn",
        ]
        return needles.contains { lower.contains($0) }
    }

    private static func makeScrollableDetailsView(
        _ text: String,
        width: CGFloat = 440,
        height: CGFloat = 200,
        maxCharacters: Int = 20000) -> NSView
    {
        let clipped = text.count > maxCharacters
            ? String(text.prefix(maxCharacters)) + "\n…"
            : text

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.string = clipped

        scrollView.documentView = textView
        return scrollView
    }

    func presentInitialNoCoreSetupGuideIfNeeded() {
        guard self.shouldPresentInitialNoCoreSetupGuide() else { return }
        guard !didPresentInitialNoCoreSetupGuide else { return }

        didPresentInitialNoCoreSetupGuide = true
        defaults.set(true, forKey: initialNoCoreSetupGuideShownKey)

        let informative = tr(
            "app.core.setup_required.message",
            workingDirectoryManager.coreDirectoryURL.path)

        Task { [weak self] in
            guard let self else { return }
            let response = await self.presentAlert(
                style: .informational,
                message: tr("app.core.setup_required.title"),
                informative: informative,
                buttons: [tr("ui.action.open_core_directory"), tr("ui.action.ok")])
            if response == .alertFirstButtonReturn {
                self.showCoreDirectoryInFinder()
            }
        }
    }

    func shouldPresentInitialNoCoreSetupGuide() -> Bool {
        guard self.shouldDeferAutoStartForMissingManagedCore() else { return false }
        guard !defaults.bool(forKey: initialNoCoreSetupGuideShownKey) else { return false }
        return true
    }
}

/// The window used for alerts.
///
/// Must be an `NSPanel`: `ClashBarAppDelegate.suppressWindowIfNeeded` closes every plain
/// `NSWindow` that is not a status-bar/popover window, and it runs on
/// `NSWindow.didBecomeKeyNotification`. A plain `NSWindow` alert therefore vanished the moment
/// the user clicked it (that click is what makes it key). Panels are skipped by that filter, and
/// the class name still contains "Alert" so the name-based fallback also accepts it.
final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the alert window and keeps the calling task suspended until the user answers.
///
/// Deliberately built on a plain window plus buttons instead of `NSAlert.runModal()`: there
/// is no modal event loop, so a window that fails to appear can no longer freeze the app, and
/// nothing can nest inside a stuck modal session.
@MainActor
final class AlertWindowController: NSObject {
    static let shared = AlertWindowController()

    private var window: NSWindow?
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    private var autoDismissWorkItem: DispatchWorkItem?
    private var closeObserver: NSObjectProtocol?

    func present(
        style: NSAlert.Style,
        message: String,
        informative: String,
        buttons: [String],
        accessory: NSView?,
        level: NSWindow.Level,
        autoDismissAfter seconds: TimeInterval?) async -> NSApplication.ModalResponse
    {
        // Never stack alerts. A second request while one is visible returns immediately instead
        // of opening another window on top of the first one.
        guard self.window == nil else { return .abort }

        return await withCheckedContinuation { (continuation: CheckedContinuation<
            NSApplication.ModalResponse, Never>) in
            self.continuation = continuation
            self.showAlert(
                style: style,
                message: message,
                informative: informative,
                buttons: buttons,
                accessory: accessory,
                level: level,
                autoDismissAfter: seconds)
        }
    }

    private func showAlert(
        style: NSAlert.Style,
        message: String,
        informative: String,
        buttons: [String],
        accessory: NSView?,
        level: NSWindow.Level,
        autoDismissAfter seconds: TimeInterval?)
    {
        let titles = buttons.isEmpty ? ["OK"] : buttons
        let padding: CGFloat = 20
        let iconSize: CGFloat = 40
        let buttonsHeight: CGFloat = 26
        let buttonsGap: CGFloat = 16
        let accessoryGap: CGFloat = 14

        // `fittingSize` is zero for a plain container that positions its children with frames
        // instead of constraints (the import dialog does exactly that), so fall back to the
        // view's own frame size in that case.
        let accessorySize = Self.measuredSize(of: accessory)
        let width: CGFloat = max(420, accessorySize.width + padding * 2 + 8)
        let textLeft = padding + iconSize + 14
        let textWidth = max(120, width - textLeft - padding)

        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let titleHeight = Self.textHeight(message, font: titleFont, width: textWidth)
        let bodyHeight = informative.isEmpty
            ? 0
            : Self.textHeight(informative, font: bodyFont, width: textWidth)
        let bodyGap: CGFloat = bodyHeight > 0 ? 4 : 0

        let accessoryHeight = accessorySize.height
        let effectiveAccessoryGap: CGFloat = accessoryHeight > 0 ? accessoryGap : 0

        let textBlockHeight = titleHeight + bodyGap + bodyHeight
        let contentHeight = padding + max(iconSize, textBlockHeight)
            + effectiveAccessoryGap + accessoryHeight
            + buttonsGap + buttonsHeight + padding

        let window = AlertPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "ClashBar"
        window.isReleasedWhenClosed = false
        window.level = level
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false

        // Route the title-bar close button to our own handler so the pending continuation is
        // always resumed; without this the window would close while a task waits forever.
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(self.alertCloseButtonPressed(_:))
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        content.autoresizingMask = [.width, .height]

        let buttonsY = padding
        let accessoryY = buttonsY + buttonsHeight + buttonsGap
        let textBottom = accessoryY + accessoryHeight + effectiveAccessoryGap

        let iconView = NSImageView(frame: NSRect(
            x: padding,
            y: contentHeight - padding - iconSize,
            width: iconSize,
            height: iconSize))
        iconView.image = Self.icon(for: style)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(iconView)

        if bodyHeight > 0 {
            let bodyLabel = NSTextField(wrappingLabelWithString: informative)
            bodyLabel.font = bodyFont
            bodyLabel.textColor = .secondaryLabelColor
            bodyLabel.isSelectable = false
            bodyLabel.frame = NSRect(x: textLeft, y: textBottom, width: textWidth, height: bodyHeight)
            content.addSubview(bodyLabel)
        }

        let titleLabel = NSTextField(wrappingLabelWithString: message)
        titleLabel.font = titleFont
        titleLabel.textColor = .labelColor
        titleLabel.isSelectable = false
        titleLabel.frame = NSRect(
            x: textLeft,
            y: textBottom + bodyHeight + bodyGap,
            width: textWidth,
            height: titleHeight)
        content.addSubview(titleLabel)

        if let accessory, accessoryHeight > 0 {
            let accessoryWidth = min(width - padding * 2, max(accessorySize.width, 120))
            accessory.frame = NSRect(
                x: (width - accessoryWidth) / 2,
                y: accessoryY,
                width: accessoryWidth,
                height: accessoryHeight)
            content.addSubview(accessory)
        }

        var buttonX = width - padding
        for (index, title) in titles.enumerated().reversed() {
            let button = NSButton(title: title, target: self, action: #selector(self.alertButtonPressed(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.keyEquivalent = index == 0
                ? "\r"
                : (index == titles.count - 1 ? "\u{1b}" : "")
            button.sizeToFit()
            let buttonWidth = max(button.frame.width, 72)
            button.frame = NSRect(
                x: buttonX - buttonWidth,
                y: buttonsY,
                width: buttonWidth,
                height: buttonsHeight)
            buttonX -= buttonWidth + 10
            content.addSubview(button)
        }

        window.contentView = content
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Anything that closes the window behind our back (Cmd-W, AppKit close) must resume the
        // waiting task, otherwise the import flow would silently never finish.
        self.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(.abort)
            }
        }

        if let seconds, seconds > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.finish(.abort)
                }
            }
            self.autoDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
        }

        // If the window still is not on screen a moment later, give up instead of waiting for an
        // answer that can never arrive.
        let createdWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.window, current === createdWindow else { return }
                guard !current.isVisible else { return }
                self.finish(.abort)
            }
        }
    }

    @objc private func alertButtonPressed(_ sender: NSButton) {
        let response = NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag)
        self.finish(response)
    }

    @objc private func alertCloseButtonPressed(_ sender: Any?) {
        self.finish(.abort)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let window = self.window else { return }
        self.window = nil

        self.autoDismissWorkItem?.cancel()
        self.autoDismissWorkItem = nil

        if let closeObserver = self.closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }

        window.orderOut(nil)

        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: response)
    }

    private static func measuredSize(of view: NSView?) -> NSSize {
        guard let view else { return .zero }
        let fitting = view.fittingSize
        if fitting.width > 1, fitting.height > 1 {
            return fitting
        }
        return view.frame.size
    }

    private static func icon(for style: NSAlert.Style) -> NSImage? {
        switch style {
        case .critical, .warning:
            return NSImage(named: NSImage.cautionName)
        default:
            return NSApp.applicationIconImage
        }
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)
        return ceil(rect.height) + 1
    }
}
