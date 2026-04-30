import AppKit
import SwiftUI

struct StatusPanelView: View {
    @ObservedObject var model: CodexStatusModel
    @AppStorage(LimitDisplayMode.storageKey) private var limitDisplayModeRaw = LimitDisplayMode.remaining.rawValue
    @AppStorage(MenuBarDisplayVersion.storageKey) private var menuBarDisplayVersionRaw = MenuBarDisplayVersion.version1.rawValue
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            ScrollView {
                ZStack(alignment: .topLeading) {
                    if showSettings {
                        settingsContent
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    } else {
                        content
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.24), value: showSettings)

            Divider().opacity(0.5)

            footer
        }
        .frame(width: 340, height: 320)
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .onChange(of: limitDisplayModeRaw) { _ in
            model.updateMenuBarTitleForDisplayModeChange()
        }
        .onChange(of: menuBarDisplayVersionRaw) { _ in
            model.updateMenuBarTitleForDisplayModeChange()
        }
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
            ) { snapshot in
                ProviderInfoRowView(
                    icon: "creditcard",
                    title: "Credits",
                    value: creditsText(snapshot.credits)
                )

                if let plan = snapshot.planType {
                    ProviderInfoRowView(
                        icon: "person.crop.circle",
                        title: "Plan",
                        value: plan
                    )
                }
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionView(title: "MENU BAR") {
                SettingsMenuBarVersionRowView(
                    icon: "menubar.rectangle",
                    title: "Display",
                    subtitle: "Choose menu bar layout",
                    selection: $menuBarDisplayVersionRaw
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

            SettingsSectionView(title: "LINKS") {
                Button {
                    model.openDashboard()
                } label: {
                    SettingsInfoRowView(
                        icon: "arrow.up.right.square",
                        title: "Codex Dashboard",
                        subtitle: "Open Codex usage page in Safari"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 13, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)

                Text("Token Monitor")
                    .font(.system(size: 14, weight: .bold))
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.24)) {
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

            Text(lastUpdatedText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var lastUpdatedText: String {
        guard let date = model.lastUpdated else { return "Waiting" }
        return "Updated \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func creditsText(_ credits: CreditsSnapshot?) -> String {
        guard let credits else { return "Unavailable" }
        if credits.unlimited { return "Unlimited" }
        return credits.balance ?? (credits.hasCredits ? "Available" : "0")
    }

    private var limitDisplayMode: LimitDisplayMode {
        LimitDisplayMode(rawValue: limitDisplayModeRaw) ?? .remaining
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

private struct ProviderUsageSectionView<Accessory: View>: View {
    let provider: TokenProvider
    let snapshot: RateLimitsSnapshot?
    let message: String?
    let statusLabel: String?
    let displayMode: LimitDisplayMode
    @ViewBuilder let accessory: (RateLimitsSnapshot) -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                VStack(spacing: 9) {
                    LimitCardView(
                        title: "5h",
                        window: snapshot.primary,
                        showsWeekScale: false,
                        displayMode: displayMode
                    )
                    LimitCardView(
                        title: "Weekly",
                        window: snapshot.secondary,
                        showsWeekScale: true,
                        displayMode: displayMode
                    )
                }

                VStack(spacing: 6) {
                    Divider().opacity(0.35)
                    accessory(snapshot)
                }
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.035))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.055), lineWidth: 1)
                    }
            }
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

private struct ProviderInfoRowView: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.system(size: 11))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsPickerRowView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var selection: String

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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Picker("", selection: $selection) {
                ForEach(LimitDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 136)
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsMenuBarVersionRowView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var selection: String

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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Picker("", selection: $selection) {
                ForEach(MenuBarDisplayVersion.allCases) { version in
                    Text(version.title).tag(version.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 92)
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsToggleRowView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

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

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
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
    let title: String
    let window: RateLimitWindow?
    let showsWeekScale: Bool
    let displayMode: LimitDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Text(percentText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(resetText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 82, alignment: .trailing)
            }

            if showsWeekScale {
                SegmentedUsageBarView(value: displayMode.barValue(for: window), tint: tintColor)
            } else {
                UsageBarView(value: displayMode.barValue(for: window), tint: tintColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }

    private var percentText: String {
        guard let percent = displayMode.percent(for: window) else { return "--" }
        return "\(percent)%"
    }

    private var resetText: String {
        guard let resetDate = window?.resetDate else { return "Reset unavailable" }
        let relativeText = relativeResetText(until: resetDate)
        let absoluteText: String

        if window?.windowDurationMins == 300 || Calendar.current.isDateInToday(resetDate) {
            absoluteText = resetDate.formatted(date: .omitted, time: .shortened)
        } else {
            absoluteText = resetDate.formatted(.dateTime.month(.abbreviated).day())
        }

        return "\(absoluteText) (\(relativeText))"
    }

    private func relativeResetText(until resetDate: Date) -> String {
        let seconds = max(0, Int(resetDate.timeIntervalSinceNow))
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))

        if window?.windowDurationMins == 300 || minutes < 1_440 {
            let hours = max(1, Int(ceil(Double(minutes) / 60)))
            return "\(hours)h"
        }

        let days = max(1, Int(ceil(Double(minutes) / 1_440)))
        return "\(days)d"
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

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segmentCount, id: \.self) { index in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))

                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * fillRatio(for: index))
                    }
                }
                .frame(height: 6)
            }
        }
        .frame(height: 6)
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
