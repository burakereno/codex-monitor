import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let model: CodexMonitorModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var preferredPopoverHeight = StatusPanelLayout.initialHeight
    private var statusSymbolCache: [String: NSImage] = [:]
    private let statusSymbolConfig = NSImage.SymbolConfiguration(
        pointSize: MenuBarDisplay.metricIconPointSize,
        weight: .medium
    )

    init(model: CodexMonitorModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(
            width: StatusPanelLayout.width,
            height: StatusPanelLayout.initialHeight
        )
        popover.contentViewController = NSHostingController(
            rootView: StatusPanelView(
                model: model,
                onPreferredHeightChange: { [weak self] height in
                    self?.updatePopoverHeight(height)
                }
            )
            .frame(width: StatusPanelLayout.width)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        model.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                self?.updateMenuBarButton(title)
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            applyPreferredPopoverHeight(for: sender.window?.screen)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
            }
            Task { await model.refresh() }
        }
    }

    private func updatePopoverHeight(_ preferredHeight: CGFloat) {
        preferredPopoverHeight = preferredHeight
        applyPreferredPopoverHeight(for: statusItem.button?.window?.screen)
    }

    private func applyPreferredPopoverHeight(for screen: NSScreen?) {
        let visibleScreenHeight = screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? preferredPopoverHeight
        let height = StatusPanelLayout.clampedHeight(
            preferredPopoverHeight,
            visibleScreenHeight: visibleScreenHeight
        )

        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: StatusPanelLayout.width, height: height)
    }

    private func updateMenuBarButton(_ title: MenuBarTitle) {
        guard let button = statusItem.button else { return }

        let image = renderStatusImage(title: title)
        statusItem.length = image.size.width
        button.image = image
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.title = ""
    }

    private func renderStatusImage(title: MenuBarTitle) -> NSImage {
        let width = MenuBarDisplay.contentWidth(for: title)
        let height = MenuBarDisplay.statusHeight
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        var x = MenuBarDisplay.horizontalPadding
        for (index, providerTitle) in title.providers.enumerated() {
            x = draw(
                providerTitle: providerTitle,
                displayVersion: title.displayVersion,
                x: x,
                canvasHeight: height
            )
            if index < title.providers.count - 1 {
                x += MenuBarDisplay.providerSpacing
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func draw(
        providerTitle: MenuBarProviderTitle,
        displayVersion: MenuBarDisplayVersion,
        x: CGFloat,
        canvasHeight: CGFloat
    ) -> CGFloat {
        drawProviderIcon(providerTitle.provider, x: x, canvasHeight: canvasHeight)

        let valueX = x + MenuBarDisplay.providerIconWidth + MenuBarDisplay.iconTextSpacing
        switch displayVersion {
        case .version1:
            return drawVersion1(providerTitle: providerTitle, x: valueX, canvasHeight: canvasHeight)
        case .version2:
            return drawVersion2(providerTitle: providerTitle, x: valueX, canvasHeight: canvasHeight)
        }
    }

    private func drawVersion1(
        providerTitle: MenuBarProviderTitle,
        x valueX: CGFloat,
        canvasHeight: CGFloat
    ) -> CGFloat {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuBarDisplay.labelFont,
            .foregroundColor: NSColor.black
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuBarDisplay.valueFont,
            .foregroundColor: NSColor.black
        ]
        let resetAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuBarDisplay.resetFont,
            .foregroundColor: NSColor.black
        ]

        let primary = providerTitle.primary as NSString
        let separator = "/" as NSString
        let weekly = providerTitle.weekly as NSString
        let textHeight = max(
            max(primary.size(withAttributes: valueAttrs).height, weekly.size(withAttributes: valueAttrs).height),
            resetTextHeight(providerTitle: providerTitle, attributes: resetAttrs)
        )
        let y = floor((canvasHeight - textHeight) / 2)

        primary.draw(at: NSPoint(x: valueX, y: y), withAttributes: valueAttrs)
        let primaryEndX = valueX + primary.size(withAttributes: valueAttrs).width
        let separatorX = drawResetText(
            providerTitle.primaryReset,
            x: primaryEndX,
            y: y,
            canvasHeight: canvasHeight,
            attributes: resetAttrs
        ) + 1
        separator.draw(at: NSPoint(x: separatorX, y: y), withAttributes: labelAttrs)
        let weeklyX = separatorX + separator.size(withAttributes: labelAttrs).width + 1
        weekly.draw(at: NSPoint(x: weeklyX, y: y), withAttributes: valueAttrs)
        let weeklyEndX = weeklyX + weekly.size(withAttributes: valueAttrs).width
        return drawResetText(
            providerTitle.weeklyReset,
            x: weeklyEndX,
            y: y,
            canvasHeight: canvasHeight,
            attributes: resetAttrs
        )
    }

    private func drawVersion2(
        providerTitle: MenuBarProviderTitle,
        x valueX: CGFloat,
        canvasHeight: CGFloat
    ) -> CGFloat {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuBarDisplay.labelFont,
            .foregroundColor: NSColor.black
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuBarDisplay.valueFont,
            .foregroundColor: NSColor.black
        ]
        let resetAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuBarDisplay.resetFont,
            .foregroundColor: NSColor.black
        ]

        let primaryLabel = "5h" as NSString
        let primary = providerTitle.primary as NSString
        let weeklyLabel = "W" as NSString
        let weekly = providerTitle.weekly as NSString
        let textHeight = max(
            max(primaryLabel.size(withAttributes: labelAttrs).height, primary.size(withAttributes: valueAttrs).height),
            max(
                max(weeklyLabel.size(withAttributes: labelAttrs).height, weekly.size(withAttributes: valueAttrs).height),
                resetTextHeight(providerTitle: providerTitle, attributes: resetAttrs)
            )
        )
        let y = floor((canvasHeight - textHeight) / 2)

        primaryLabel.draw(at: NSPoint(x: valueX, y: y), withAttributes: labelAttrs)
        let primaryX = valueX + primaryLabel.size(withAttributes: labelAttrs).width + MenuBarDisplay.labelValueSpacing
        primary.draw(at: NSPoint(x: primaryX, y: y), withAttributes: valueAttrs)

        let primaryEndX = primaryX + primary.size(withAttributes: valueAttrs).width
        let afterPrimaryResetX = drawResetText(
            providerTitle.primaryReset,
            x: primaryEndX,
            y: y,
            canvasHeight: canvasHeight,
            attributes: resetAttrs
        )
        let weeklyLabelX = afterPrimaryResetX + MenuBarDisplay.version2GroupSpacing
        weeklyLabel.draw(at: NSPoint(x: weeklyLabelX, y: y), withAttributes: labelAttrs)
        let weeklyX = weeklyLabelX + weeklyLabel.size(withAttributes: labelAttrs).width + MenuBarDisplay.labelValueSpacing
        weekly.draw(at: NSPoint(x: weeklyX, y: y), withAttributes: valueAttrs)
        let weeklyEndX = weeklyX + weekly.size(withAttributes: valueAttrs).width
        return drawResetText(
            providerTitle.weeklyReset,
            x: weeklyEndX,
            y: y,
            canvasHeight: canvasHeight,
            attributes: resetAttrs
        )
    }

    private func drawResetText(
        _ reset: String?,
        x: CGFloat,
        y: CGFloat,
        canvasHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        guard let reset else { return x }

        let iconX = x + MenuBarDisplay.resetGroupSpacing
        drawSymbol("arrow.clockwise", x: iconX, canvasHeight: canvasHeight)

        let resetText = reset as NSString
        let resetX = iconX + MenuBarDisplay.metricIconWidth + MenuBarDisplay.resetIconTextSpacing
        resetText.draw(at: NSPoint(x: resetX, y: y), withAttributes: attributes)
        return resetX + resetText.size(withAttributes: attributes).width
    }

    private func resetTextHeight(
        providerTitle: MenuBarProviderTitle,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let heights = [providerTitle.primaryReset, providerTitle.weeklyReset]
            .compactMap { reset -> CGFloat? in
                guard let reset else { return nil }
                return (reset as NSString).size(withAttributes: attributes).height
            }
        return heights.max() ?? 0
    }

    private func drawProviderIcon(_ provider: TokenProvider, x: CGFloat, canvasHeight: CGFloat) {
        let icon = ProviderIcon.image(for: provider)
        let target = NSSize(width: MenuBarDisplay.providerIconWidth, height: MenuBarDisplay.providerIconWidth)
        let rect = aspectFitRect(
            imageSize: icon.size,
            targetRect: NSRect(
                x: x,
                y: floor((canvasHeight - target.height) / 2),
                width: target.width,
                height: target.height
            )
        )
        icon.draw(in: rect)
    }

    private func aspectFitRect(imageSize: NSSize, targetRect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return targetRect }

        let scale = min(targetRect.width / imageSize.width, targetRect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(
            x: targetRect.midX - width / 2,
            y: targetRect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func drawSymbol(_ symbolName: String, x: CGFloat, canvasHeight: CGFloat) {
        let symbol: NSImage
        if let cached = statusSymbolCache[symbolName] {
            symbol = cached
        } else if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(statusSymbolConfig) {
            statusSymbolCache[symbolName] = image
            symbol = image
        } else if let image = NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)?
            .withSymbolConfiguration(statusSymbolConfig) {
            symbol = image
        } else {
            return
        }

        let rect = NSRect(
            x: x + (MenuBarDisplay.metricIconWidth - symbol.size.width) / 2,
            y: (canvasHeight - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )
        symbol.draw(in: rect)
    }
}

private enum MenuBarDisplay {
    static let statusHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 2
    static let providerIconWidth: CGFloat = 14
    static let metricIconWidth: CGFloat = 14
    static let iconTextSpacing: CGFloat = 4
    static let version2GroupSpacing: CGFloat = 6
    static let providerSpacing: CGFloat = 8
    static let labelValueSpacing: CGFloat = 3
    static let resetGroupSpacing: CGFloat = 3
    static let resetIconTextSpacing: CGFloat = 1
    static let metricIconPointSize: CGFloat = 12
    static let metricTextPointSize: CGFloat = 12

    static let labelFont = NSFont.monospacedSystemFont(
        ofSize: metricTextPointSize,
        weight: .medium
    )
    static let valueFont = NSFont.monospacedSystemFont(
        ofSize: metricTextPointSize,
        weight: .bold
    )
    static let resetFont = NSFont.monospacedSystemFont(
        ofSize: metricTextPointSize - 1,
        weight: .medium
    )

    static func contentWidth(for title: MenuBarTitle) -> CGFloat {
        let providers = title.providers
        let textWidth = providers.reduce(CGFloat.zero) { partial, provider in
            partial + ceil(
                providerIconWidth
                    + iconTextSpacing
                    + contentWidth(for: provider, displayVersion: title.displayVersion)
            )
        }
        let spacings = CGFloat(max(providers.count - 1, 0)) * providerSpacing
        return ceil(horizontalPadding * 2 + textWidth + spacings)
    }

    private static func contentWidth(
        for provider: MenuBarProviderTitle,
        displayVersion: MenuBarDisplayVersion
    ) -> CGFloat {
        let attrsLabel: [NSAttributedString.Key: Any] = [.font: labelFont]
        let attrsValue: [NSAttributedString.Key: Any] = [.font: valueFont]
        let attrsReset: [NSAttributedString.Key: Any] = [.font: resetFont]
        let primaryWidth = (provider.primary as NSString).size(withAttributes: attrsValue).width
        let weeklyWidth = (provider.weekly as NSString).size(withAttributes: attrsValue).width
        let primaryResetWidth = resetWidth(provider.primaryReset, attributes: attrsReset)
        let weeklyResetWidth = resetWidth(provider.weeklyReset, attributes: attrsReset)

        switch displayVersion {
        case .version1:
            let separatorWidth = ("/" as NSString).size(withAttributes: attrsLabel).width
            return primaryWidth + primaryResetWidth + separatorWidth + weeklyWidth + weeklyResetWidth + 2
        case .version2:
            let primaryLabelWidth = ("5h" as NSString).size(withAttributes: attrsLabel).width
            let weeklyLabelWidth = ("W" as NSString).size(withAttributes: attrsLabel).width
            return primaryLabelWidth
                + labelValueSpacing
                + primaryWidth
                + primaryResetWidth
                + version2GroupSpacing
                + weeklyLabelWidth
                + labelValueSpacing
                + weeklyWidth
                + weeklyResetWidth
        }
    }

    private static func resetWidth(
        _ reset: String?,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        guard let reset else { return 0 }
        return resetGroupSpacing
            + metricIconWidth
            + resetIconTextSpacing
            + (reset as NSString).size(withAttributes: attributes).width
    }
}
