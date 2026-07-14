import AppKit
import SwiftUI

struct StatusPanelView: View {
    @ObservedObject var model: CodexMonitorModel
    let onPreferredHeightChange: (CGFloat) -> Void
    @AppStorage(LimitDisplayMode.storageKey) private var limitDisplayModeRaw = LimitDisplayMode.remaining.rawValue
    @AppStorage(MenuBarDisplayVersion.storageKey) private var menuBarDisplayVersionRaw = MenuBarDisplayVersion.version1.rawValue
    @AppStorage(MenuBarResetTimePreference.storageKey) private var showMenuBarResetTimes = false
    @AppStorage(DockIconPreference.showDockIconKey) private var showDockIcon = false
    @AppStorage(DockIconPreference.showDockValuesKey) private var showDockValues = false
    @ObservedObject private var launchAtLogin = LaunchAtLoginPreference.shared
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var showSettings = false
    @State private var showFooterUpToDate = false
    @State private var headerHeight: CGFloat = 0
    @State private var dashboardContentHeight: CGFloat = 0
    @State private var settingsContentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var lastReportedHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    headerHeight = height
                    reportPreferredHeight()
                }

            Divider().opacity(0.5)

            ZStack {
                if showSettings {
                    ScrollView {
                        settingsContent
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                settingsContentHeight = height
                                reportPreferredHeight()
                            }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                } else {
                    ScrollView {
                        content
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                dashboardContentHeight = height
                                reportPreferredHeight()
                            }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.snappy(duration: 0.24), value: showSettings)

            Divider().opacity(0.5)

            footer
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    footerHeight = height
                    reportPreferredHeight()
                }
        }
        .frame(width: StatusPanelLayout.width)
        .preferredColorScheme(.dark)
        .onChange(of: limitDisplayModeRaw) { _, _ in
            model.updateMenuBarTitleForDisplayModeChange()
        }
        .onChange(of: menuBarDisplayVersionRaw) { _, _ in
            model.updateMenuBarTitleForDisplayModeChange()
        }
        .onChange(of: showMenuBarResetTimes) { _, _ in
            model.updateMenuBarTitleForDisplayModeChange()
        }
        .onChange(of: showDockIcon) { _, _ in
            notifyDockSettingsChanged()
        }
        .onChange(of: showDockValues) { _, _ in
            notifyDockSettingsChanged()
        }
        .onChange(of: showSettings) { _, _ in
            reportPreferredHeight()
        }
        .onAppear {
            launchAtLogin.refresh()
        }
    }

    private func reportPreferredHeight() {
        let contentHeight = showSettings ? settingsContentHeight : dashboardContentHeight
        guard headerHeight > 0, contentHeight > 0, footerHeight > 0 else { return }

        let dividerHeights: CGFloat = 2
        let preferredHeight = ceil(headerHeight + contentHeight + footerHeight + dividerHeights)
        guard abs(lastReportedHeight - preferredHeight) > 0.5 else { return }

        lastReportedHeight = preferredHeight
        onPreferredHeightChange(preferredHeight)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.codexSnapshot == nil, model.codexMessage == nil {
                EmptyStatusView(message: "Codex should be installed and logged in.")
            }

            ProviderUsageSectionView(
                provider: .codex,
                snapshot: model.codexSnapshot,
                message: model.codexMessage,
                statusLabel: nil,
                displayMode: limitDisplayMode
            ) {
                VStack(spacing: 10) {
                    if let resetCredits = model.rateLimitResetCredits {
                        RateLimitResetCreditsCardView(summary: resetCredits)
                    }

                    DailyUsageCardView(days: model.codexUsageSummary.dailyUsage)

                    TokenUsageCardView(summary: model.codexUsageSummary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            LastUpdatedCardView(text: lastUpdatedText, isRefreshing: model.isRefreshing)
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionView(title: "STARTUP") {
                SettingsToggleRowView(
                    icon: "power",
                    title: "Open at Login",
                    subtitle: "Open Codex Monitor when you log in",
                    isOn: $launchAtLogin.isEnabled
                )
            }

            SettingsSectionView(title: "MENU BAR") {
                SettingsMenuBarVersionRowView(
                    icon: "menubar.rectangle",
                    title: "Display",
                    subtitle: "Choose menu bar layout",
                    selection: $menuBarDisplayVersionRaw
                )

                Divider()
                    .opacity(0.35)
                    .padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "clock.arrow.circlepath",
                    title: "Reset Times",
                    subtitle: "Show reset countdowns in the menu bar",
                    isOn: $showMenuBarResetTimes
                )
            }

            SettingsSectionView(title: "DOCK") {
                SettingsToggleRowView(
                    icon: "dock.rectangle",
                    title: "Dock Icon",
                    subtitle: "Show Codex Monitor in the Dock",
                    isOn: $showDockIcon
                )

                Divider()
                    .opacity(0.35)
                    .padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "number.square",
                    title: "Values",
                    subtitle: "Show the 5h value on the Dock icon",
                    isOn: $showDockValues,
                    disabled: !showDockIcon
                )
            }

            SettingsSectionView(title: "USAGE BARS") {
                SettingsPickerRowView(
                    icon: "chart.bar.xaxis",
                    title: "Usage Logic",
                    subtitle: limitDisplayMode.description,
                    selection: $limitDisplayModeRaw
                )

                Divider()
                    .opacity(0.35)
                    .padding(.vertical, 5)

                SettingsUsagePreviewView(
                    snapshot: model.codexSnapshot,
                    displayMode: limitDisplayMode
                )
            }

            SettingsAboutCardView(updater: updater)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 13, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)

                Text("Codex Monitor")
                    .font(.system(size: 14, weight: .bold))
            }

            Spacer()

            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: showSettings ? "xmark.circle.fill" : "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(showSettings ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(showSettings ? "Close Settings" : "Settings")
            .accessibilityLabel(showSettings ? "Close Settings" : "Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }

                    Text(model.isRefreshing ? "Refreshing" : "Refresh")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
            .help(model.isRefreshing ? "Refreshing" : "Refresh")
            .accessibilityLabel("Refresh")

            Spacer()

            footerTrailingActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footerTrailingActions: some View {
        HStack(spacing: 8) {
            if updater.updateAvailable, let latestVersion = updater.latestVersion {
                UpdateButton(version: latestVersion)
            } else {
                footerVersionStatus
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.06))
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private var footerVersionStatus: some View {
        Button {
            Task { await updater.checkForUpdates(force: true) }
        } label: {
            HStack(spacing: 6) {
                if updater.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }

                Text(footerUpdateText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(footerUpdateColor)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(updater.isChecking)
        .fixedSize(horizontal: true, vertical: false)
        .help(updater.isChecking ? "Checking for Updates" : "Check for Updates")
        .accessibilityLabel("Check for Updates")
        .animation(.easeInOut(duration: 0.18), value: updater.isChecking)
        .animation(.easeInOut(duration: 0.18), value: updater.lastCheckCompletedAt)
        .onChange(of: updater.lastCheckCompletedAt) { _, _ in
            guard updater.isUpToDate else { return }
            Task {
                showFooterUpToDate = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                showFooterUpToDate = false
            }
        }
    }

    private var footerUpdateText: String {
        if updater.isChecking { return "Checking" }
        if updater.lastError != nil { return "Check failed" }
        if showFooterUpToDate { return "Up to date" }
        return "v\(appVersion)"
    }

    private var footerUpdateColor: Color {
        if updater.lastError != nil { return .red }
        if showFooterUpToDate { return .green }
        return .secondary
    }

    private var lastUpdatedText: String {
        guard let date = model.lastUpdated else { return "Waiting" }
        return "Updated \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var limitDisplayMode: LimitDisplayMode {
        LimitDisplayMode(rawValue: limitDisplayModeRaw) ?? .remaining
    }

    private func notifyDockSettingsChanged() {
        NotificationCenter.default.post(name: .codexMonitorDockSettingsChanged, object: nil)
    }

}

enum LimitDisplayMode: String, CaseIterable, Identifiable {
    case remaining
    case used

    static let storageKey = "limitDisplayMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remaining:
            return "Remaining"
        case .used:
            return "Used"
        }
    }

    var description: String {
        switch self {
        case .remaining:
            return "Bars and values show remaining quota"
        case .used:
            return "Bars and values show consumed quota"
        }
    }

    func percent(for window: RateLimitWindow?) -> Int? {
        switch self {
        case .remaining:
            return window?.remainingPercent
        case .used:
            return window?.usedPercent
        }
    }

    func barValue(for window: RateLimitWindow?) -> Double {
        Double(percent(for: window) ?? 0) / 100
    }

    func tint(for window: RateLimitWindow?) -> Color {
        switch window?.remainingColorLevel {
        case .high:
            return .green
        case .medium:
            return .orange
        case .low:
            return .red
        case .none:
            return .secondary
        }
    }
}

private struct StatJackCardBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(cardFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(cardHighlight, lineWidth: 0.5)
                    }
                    .shadow(color: cardShadow, radius: 8, y: 2)
            }
    }

    private var cardFill: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.30)
        }
        return Color.black.opacity(0.03)
    }

    private var cardHighlight: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.07)
        }
        return Color.black.opacity(0.045)
    }

    private var cardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.065)
    }
}

private enum StatusSectionLayout {
    static let contentPadding: CGFloat = 16
    static let titleFontSize: CGFloat = 12
}

private extension View {
    func statJackCardBackground(cornerRadius: CGFloat = 10) -> some View {
        modifier(StatJackCardBackground(cornerRadius: cornerRadius))
    }

    func statusSectionCard() -> some View {
        padding(StatusSectionLayout.contentPadding)
            .statJackCardBackground()
    }
}

private func formattedTokenCount(_ value: Int) -> String {
    let sign = value < 0 ? "-" : ""
    let absolute = abs(value)

    if absolute >= 1_000_000 {
        let formatted = Double(absolute) / 1_000_000
        return "\(sign)\(String(format: formatted >= 10 ? "%.0f" : "%.1f", formatted))M"
    }

    if absolute >= 1_000 {
        let formatted = Double(absolute) / 1_000
        return "\(sign)\(String(format: formatted >= 10 ? "%.0f" : "%.1f", formatted))k"
    }

    return "\(value)"
}

private struct ProviderUsageSectionView<Accessory: View>: View {
    let provider: TokenProvider
    let snapshot: RateLimitsSnapshot?
    let message: String?
    let statusLabel: String?
    let displayMode: LimitDisplayMode
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ProviderIconView(provider: provider, size: 15)
                    .foregroundStyle(.primary)

                Text(provider.displayName)
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            if let snapshot {
                VStack(spacing: 10) {
                    LimitCardView(
                        icon: "clock",
                        title: "5-Hour Session",
                        window: snapshot.primary,
                        showsWeekScale: false,
                        displayMode: displayMode
                    )
                    LimitCardView(
                        icon: "calendar",
                        title: "Weekly Limit",
                        window: snapshot.secondary,
                        showsWeekScale: true,
                        displayMode: displayMode
                    )
                }
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .statJackCardBackground()
            }

            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        statusLabel ?? (snapshot == nil ? "Waiting" : "Live")
    }

    private var statusColor: Color {
        switch statusText {
        case "Live":
            return .green
        case "Snapshot", "Running":
            return .orange
        default:
            return .secondary
        }
    }
}

private struct RateLimitResetCreditsCardView: View {
    let summary: RateLimitResetCreditsSummary

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: 6),
        count: 3
    )

    private var credits: [RateLimitResetCredit] {
        summary.credits ?? []
    }

    private var availabilityText: String {
        "\(summary.availableCount) available"
    }

    private var emptyText: String {
        if summary.availableCount == 0 {
            return "No resets available"
        }
        return "Reset details are currently unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeaderView(
                icon: "arrow.counterclockwise.circle",
                title: "Usage Limit Resets",
                trailing: availabilityText
            )

            if credits.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(credits) { credit in
                        RateLimitResetCreditTagView(credit: credit)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .statusSectionCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage limit resets")
    }
}

private struct RateLimitResetCreditTagView: View {
    let credit: RateLimitResetCredit

    var body: some View {
        expirationText
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(Color.green.opacity(0.09))
                    .overlay {
                        Capsule()
                            .stroke(Color.green.opacity(0.22), lineWidth: 0.5)
                    }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let expirationDate = credit.expirationDate else {
            return "No expiration date"
        }

        let date = expirationDate.formatted(.dateTime.month(.wide).day())
        let remaining = ResetTimeFormatting.detailedRemaining(until: expirationDate)
        return "Expires \(date), \(remaining) remaining"
    }

    private var expirationText: Text {
        guard let expirationDate = credit.expirationDate else {
            return Text("No expiry")
                .foregroundColor(.secondary)
        }

        return Text(expirationDate, format: .dateTime.month(.abbreviated).day())
            .foregroundColor(.white)
        + Text(" · \(ResetTimeFormatting.detailedRemaining(until: expirationDate))")
            .foregroundColor(.secondary)
    }
}

private struct DailyUsageCardView: View {
    let days: [DailyTokenUsage]

    private var maxTokens: Int {
        max(days.map(\.totalTokens).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeaderView(
                icon: "chart.bar",
                title: "Daily Usage",
                trailing: "15d"
            )

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    DailyUsageBarView(
                        day: day,
                        maxTokens: maxTokens,
                        tooltipHorizontalOffset: tooltipHorizontalOffset(for: day)
                    )
                }
            }
            .frame(height: 80, alignment: .bottom)
        }
        .statusSectionCard()
    }

    private func tooltipHorizontalOffset(for day: DailyTokenUsage) -> CGFloat {
        if day.id == days.first?.id { return 24 }
        if day.id == days.last?.id { return -24 }
        return 0
    }
}

private struct DailyUsageBarView: View {
    let day: DailyTokenUsage
    let maxTokens: Int
    let tooltipHorizontalOffset: CGFloat
    @State private var isHovered = false

    private var ratio: Double {
        guard maxTokens > 0 else { return 0 }
        return min(max(Double(day.totalTokens) / Double(maxTokens), 0), 1)
    }

    private var barHeight: CGFloat {
        day.totalTokens == 0 ? 5 : CGFloat(10 + ratio * 30)
    }

    private var isMonday: Bool {
        Calendar.current.component(.weekday, from: day.date) == 2
    }

    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(barColor)
                .frame(height: barHeight)
                .frame(maxWidth: .infinity)
                .frame(height: 58, alignment: .bottom)
                .overlay(alignment: .bottom) {
                    if isHovered {
                        Text("\(day.totalTokens.formatted()) tokens")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background {
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .overlay {
                                        Capsule()
                                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                    }
                                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                                }
                            .offset(x: tooltipHorizontalOffset, y: -(barHeight + 7))
                    }
                }

            Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 9, weight: isMonday ? .bold : .medium))
                .foregroundStyle(isMonday ? Color.green : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity, minHeight: 75, maxHeight: 75, alignment: .bottom)
        .overlay(alignment: .leading) {
            if isMonday {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 0.5, height: 58)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(x: -2)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .zIndex(isHovered ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(day.totalTokens.formatted()) tokens")
    }

    private var barColor: Color {
        if day.totalTokens == 0 { return Color.primary.opacity(0.10) }
        if ratio >= 0.72 { return .orange }
        return .green
    }
}

private struct TokenUsageCardView: View {
    let summary: CodexUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeaderView(icon: "number", title: "Token Usage", trailing: nil)

            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    tokenHeader("Input")
                    tokenHeader("Output")
                    tokenHeader("Cache")
                    tokenHeader("Total")
                }

                TokenUsageGridRowView(title: "Today", totals: summary.today)
                TokenUsageGridRowView(title: "This Month", totals: summary.currentMonth)
            }

            Divider()
                .opacity(0.35)

            if summary.modelBreakdown.isEmpty {
                Text("No model usage yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Model Usage")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    ForEach(summary.modelBreakdown) { usage in
                        HStack(spacing: 8) {
                            Text(displayModelName(usage.model))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)

                            Spacer(minLength: 8)

                            Text(formattedTokenCount(usage.totalTokens))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Text("\(usage.percentage)%")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .statusSectionCard()
    }

    private func tokenHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private func displayModelName(_ model: String) -> String {
        model == "unknown" ? "Unknown model" : model
    }
}

private struct TokenUsageGridRowView: View {
    let title: String
    let totals: TokenUsageTotals

    var body: some View {
        GridRow {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .gridColumnAlignment(.leading)

            tokenValue(totals.inputTokens)
            tokenValue(totals.outputTokens)
            tokenValue(totals.cachedInputTokens)
            tokenValue(totals.totalTokens)
        }
    }

    private func tokenValue(_ value: Int) -> some View {
        Text(formattedTokenCount(value))
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(value == 0 ? .secondary : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

private struct CardHeaderView: View {
    let icon: String
    let title: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 15)

            Text(title)
                .font(.system(size: StatusSectionLayout.titleFontSize, weight: .semibold))

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        Capsule()
                            .fill(Color.green.opacity(0.12))
                    }
            }
        }
    }
}

private struct LastUpdatedCardView: View {
    let text: String
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(isRefreshing ? "Refreshing Codex" : text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .statJackCardBackground(cornerRadius: 8)
    }
}

private struct SettingsSectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .statJackCardBackground()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsPickerRowView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var selection: String
    private let pickerWidth: CGFloat = 136

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            Picker("", selection: $selection) {
                ForEach(LimitDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .frame(width: pickerWidth, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct SettingsMenuBarVersionRowView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var selection: String
    private let pickerWidth: CGFloat = 136

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            Picker("", selection: $selection) {
                ForEach(MenuBarDisplayVersion.allCases) { version in
                    Text(version.title).tag(version.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .frame(width: pickerWidth, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct SettingsToggleRowView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(disabled ? .tertiary : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(disabled ? .tertiary : .primary)

                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsInfoRowView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

private struct SettingsAboutCardView: View {
    @ObservedObject var updater: UpdateChecker
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ABOUT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(headerForeground)
                    .tracking(0.5)

                Spacer(minLength: 8)

                updateCheckButton
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Codex Monitor")
                            .font(.system(size: 13, weight: .bold))

                        Text("Version \(updater.currentVersion)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text("Lightweight Codex usage monitor for macOS")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    updateStatusText
                }

                Spacer(minLength: 8)

                if updater.updateAvailable, let latestVersion = updater.latestVersion {
                    UpdateButton(version: latestVersion)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(cardFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(cardHighlight, lineWidth: 0.5)
                }
                .shadow(color: cardShadow, radius: 8, y: 2)
        }
    }

    private var updateCheckButton: some View {
        Button {
            Task { await updater.checkForUpdates(force: true) }
        } label: {
            HStack(spacing: 4) {
                if updater.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                }

                Text(updateCheckButtonTitle)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(updateCheckButtonForeground)
            .frame(width: 86, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(updater.isChecking ? 0.035 : 0.06))
            }
        }
        .buttonStyle(.plain)
        .frame(width: 86, height: 24)
        .contentShape(Rectangle())
        .disabled(updater.isChecking)
        .help(updater.isChecking ? "Checking for Updates" : "Check for Updates")
        .animation(.easeInOut(duration: 0.18), value: updater.isChecking)
        .animation(.easeInOut(duration: 0.18), value: updater.lastCheckCompletedAt)
    }

    private var updateCheckButtonTitle: String {
        if updater.isChecking { return "Checking" }
        if updater.lastError != nil { return "Failed" }
        if updater.isUpToDate && updater.lastCheckCompletedAt != nil { return "Up to date" }
        return "Check"
    }

    private var updateCheckButtonForeground: Color {
        if updater.isChecking { return Color(nsColor: .tertiaryLabelColor) }
        if updater.lastError != nil { return .red }
        if updater.isUpToDate && updater.lastCheckCompletedAt != nil { return .green }
        return .secondary
    }

    @ViewBuilder
    private var updateStatusText: some View {
        if updater.isChecking {
            Text("Checking for updates...")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else if updater.updateAvailable, let latestVersion = updater.latestVersion {
            Text("Version \(latestVersion) available")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else if updater.lastError != nil {
            Text("Update check failed")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        } else if updater.isUpToDate && updater.lastCheckCompletedAt != nil {
            Text("Up to date")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        }
    }

    private var cardFill: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.30)
        }
        return Color.black.opacity(0.03)
    }

    private var cardHighlight: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.07)
        }
        return Color.black.opacity(0.045)
    }

    private var cardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.065)
    }

    private var headerForeground: Color {
        if colorScheme == .dark {
            return Color(nsColor: .secondaryLabelColor)
        }
        return Color(nsColor: .tertiaryLabelColor)
    }
}

private struct SettingsUsagePreviewView: View {
    let snapshot: RateLimitsSnapshot?
    let displayMode: LimitDisplayMode

    private var primaryWindow: RateLimitWindow {
        snapshot?.primary ?? RateLimitWindow(usedPercent: 35, resetsAt: nil, windowDurationMins: 300)
    }

    private var weeklyWindow: RateLimitWindow {
        snapshot?.secondary ?? RateLimitWindow(usedPercent: 72, resetsAt: nil, windowDurationMins: 10_080)
    }

    var body: some View {
        VStack(spacing: 7) {
            previewRow(title: "5h", window: primaryWindow, segmented: false)
            previewRow(title: "Weekly", window: weeklyWindow, segmented: true)
        }
        .padding(.vertical, 2)
    }

    private func previewRow(title: String, window: RateLimitWindow, segmented: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            if segmented {
                SegmentedUsageBarView(value: displayMode.barValue(for: window), tint: displayMode.tint(for: window))
            } else {
                UsageBarView(value: displayMode.barValue(for: window), tint: displayMode.tint(for: window))
            }

            Text("\(displayMode.percent(for: window) ?? 0)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct EmptyStatusView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text("No Status Yet")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
    }
}

private struct LimitCardView: View {
    let icon: String
    let title: String
    let window: RateLimitWindow?
    let showsWeekScale: Bool
    let displayMode: LimitDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tintColor)
                        .frame(width: 16)

                    Text(title)
                        .font(.system(size: StatusSectionLayout.titleFontSize, weight: .semibold))
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(percentText)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(tintColor)
                }
            }

            if showsWeekScale {
                SegmentedUsageBarView(value: displayMode.barValue(for: window), tint: tintColor)
            } else {
                UsageBarView(value: displayMode.barValue(for: window), tint: tintColor)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                resetText
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                Text(paceText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tintColor)
                    .lineLimit(1)
            }
        }
        .statusSectionCard()
    }

    private var percentText: String {
        guard let percent = displayMode.percent(for: window) else { return "--" }
        return "\(percent)%"
    }

    private var resetText: Text {
        guard let resetDate = window?.resetDate else {
            return Text("Resets unavailable")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }

        let components = resetTextComponents(for: resetDate)

        return Text("Resets in: ")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
        + Text(components.relative)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
        + Text(" at ")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
        + Text(components.absolute)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
    }

    private func resetTextComponents(for resetDate: Date) -> (relative: String, absolute: String) {
        let relativeText = ResetTimeFormatting.detailedRemaining(until: resetDate)
        let timeText = resetDate.formatted(date: .omitted, time: .shortened)
        let absoluteText: String

        if window?.windowDurationMins == 300 {
            absoluteText = timeText
        } else {
            let dateText = resetDate.formatted(.dateTime.month(.abbreviated).day())
            absoluteText = "\(dateText), \(timeText)"
        }

        return (relativeText, absoluteText)
    }

    private var paceText: String {
        guard let window else { return "Pace: waiting" }
        return "Pace: \(window.pace.title)"
    }

    private var tintColor: Color {
        displayMode.tint(for: window)
    }

}

private struct UsageBarView: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(tint)
                    .frame(width: max(6, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

private struct SegmentedUsageBarView: View {
    let value: Double
    let tint: Color

    private let segmentCount = 7
    private let segmentHeight: CGFloat = 6

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segmentCount, id: \.self) { index in
                GeometryReader { geometry in
                    let ratio = fillRatio(for: index)

                    Capsule()
                        .fill(ratio >= 1 ? tint : Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            if ratio > 0, ratio < 1 {
                                Capsule()
                                    .fill(tint)
                                    .frame(
                                        width: min(
                                            geometry.size.width,
                                            max(segmentHeight, geometry.size.width * ratio)
                                        )
                                    )
                            }
                        }
                        .clipShape(Capsule())
                }
                .frame(height: segmentHeight)
            }
        }
        .frame(height: segmentHeight)
    }

    private func fillRatio(for index: Int) -> Double {
        let clamped = min(max(value, 0), 1)
        let segmentStart = Double(index) / Double(segmentCount)
        let segmentEnd = Double(index + 1) / Double(segmentCount)

        if clamped >= segmentEnd { return 1 }
        if clamped <= segmentStart { return 0 }
        return (clamped - segmentStart) / (segmentEnd - segmentStart)
    }
}
