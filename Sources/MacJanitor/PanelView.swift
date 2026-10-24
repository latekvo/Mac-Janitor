import AppKit
import JanitorCore
import SwiftUI

enum Metrics {
    static let width: CGFloat = 300
    static let inset: CGFloat = 12
    static let icon: CGFloat = 20
    /// The trailing column: category toggles, item pins.
    static let trailing: CGFloat = 30
}

struct PanelView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Group {
            if store.showSettings {
                SettingsView()
            } else {
                MainView()
            }
        }
        .frame(width: Metrics.width)
    }
}

private struct MainView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, Metrics.inset)
                .padding(.top, Metrics.inset)
                .padding(.bottom, 10)
            if let problem = store.problem {
                ProblemBanner(text: problem) { store.problem = nil }
                    .padding(.horizontal, Metrics.inset)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) {
                ForEach(JanitorCore.Category.allCases, id: \.self) { CategoryRow(category: $0) }
            }
            .padding(.horizontal, 6)
            CleanButton()
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 10)
            FooterView()
                .padding(.horizontal, Metrics.inset)
                .padding(.vertical, 10)
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let free = Format.byteParts(store.freeBytes)
        let tint: Color = store.isLowDisk ? .red : .primary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(free.number)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(" \(free.unit)")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                    Text("  free")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(tint)
                .help(store.isLowDisk ? "Below \(Format.number(store.config.lowDiskGB)) GB" : "")
                Spacer()
                // The clean button shows its own progress.
                if store.busy != nil, store.busy != .cleaning {
                    ProgressView().controlSize(.small)
                }
                Button { store.showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Settings")
            }
            CapacityBar(fraction: store.usedFraction, tint: store.isLowDisk ? .red : .accentColor)
                .help("\(Format.bytes(store.totalBytes - store.freeBytes)) of \(Format.bytes(store.totalBytes)) used")
        }
    }
}

private struct CapacityBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

struct ProblemBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "xmark.octagon.fill")
            Text(text)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption2.bold()) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Categories

private struct CategoryRow: View {
    @EnvironmentObject private var store: Store
    let category: JanitorCore.Category
    @State private var hovering = false

    var body: some View {
        let enabled = store.config.enabled(category)
        let items = store.items(category)
        let expanded = store.expanded == category && !items.isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: category.symbol)
                    .font(.system(size: 13))
                    .frame(width: Metrics.icon)
                    .foregroundStyle(enabled ? Color.accentColor : .secondary)
                Text(category.title)
                    .foregroundStyle(enabled ? .primary : .secondary)
                if enabled, !items.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                let issues = store.issues(category)
                if enabled, !issues.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(issues.joined(separator: "\n"))
                }
                Spacer(minLength: 4)
                if enabled { SizeLabel(category: category) }
                Toggle(category.title, isOn: Binding(get: { enabled }, set: { store.setEnabled(category, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .frame(width: Metrics.trailing, alignment: .trailing)
                    .help(enabled ? "Turn off" : "Turn on")
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(hovering && !items.isEmpty ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                guard !items.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.15)) { store.expanded = expanded ? nil : category }
            }
            if expanded {
                ItemList(items: items)
            }
        }
    }
}

private struct SizeLabel: View {
    @EnvironmentObject private var store: Store
    let category: JanitorCore.Category

    var body: some View {
        if store.covers(category) {
            let bytes = store.plannedBytes(category)
            if bytes > 0 {
                Text(Format.bytes(bytes)).monospacedDigit()
            } else {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .help("Nothing to clean")
            }
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: 38, height: 9)
                .help(store.busy == .previewing ? "Checking..." : "Not checked yet")
        }
    }
}

private struct ItemList: View {
    let items: [Item]
    @State private var height: CGFloat = 0

    var body: some View {
        // A ScrollView in a MenuBarExtra window collapses unless given a height.
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items) { ItemRow(item: $0) }
            }
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { height = geo.size.height }
                    .onChange(of: geo.size.height) { height = $0 }
            })
        }
        .frame(height: min(height, 220))
        .padding(.bottom, 4)
    }
}

private struct ItemRow: View {
    @EnvironmentObject private var store: Store
    let item: Item

    var body: some View {
        let hovering = store.hoveredItem == item.id
        HStack(spacing: 8) {
            Color.clear.frame(width: Metrics.icon, height: 1)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(nameStyle)
            Spacer(minLength: 8)
            if item.bytes > 0, item.kind != .guarded {
                Text(Format.bytes(item.bytes))
                    .monospacedDigit()
                    .foregroundStyle(item.kind == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            trailing(hovering: hovering)
                .frame(width: Metrics.trailing)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .contentShape(Rectangle())
        .help("\(Format.path(item.target))\n\(item.detail)")
        .onHover { inside in
            if inside {
                store.hoveredItem = item.id
            } else if store.hoveredItem == item.id {
                store.hoveredItem = nil
            }
        }
    }

    private var nameStyle: AnyShapeStyle {
        switch item.kind {
        case .failed: return AnyShapeStyle(.red)
        case .guarded, .pending: return AnyShapeStyle(.tertiary)
        case .planned, .kept: return AnyShapeStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trailing(hovering: Bool) -> some View {
        switch item.kind {
        case .planned:
            Button { store.pin(item.target) } label: { Image(systemName: "pin") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Keep")
                .opacity(hovering ? 1 : 0)
        case .kept:
            Button { store.unpin(item.target) } label: { Image(systemName: "pin.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("Kept, click to unpin")
        case .guarded:
            Image(systemName: "lock.fill").foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            Image(systemName: "pin.slash").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Clean and footer

private struct CleanButton: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let total = store.planned.reduce(0) { $0 + $1.bytes }
        Button { Task { await store.clean() } } label: {
            HStack(spacing: 6) {
                if store.busy == .cleaning {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Cleaning")
                } else {
                    Image(systemName: "sparkles")
                    Text(total > 0 ? "Clean \(Format.bytes(total))" : "Clean").monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ProminentButtonStyle(active: store.busy == .cleaning))
        .disabled(store.busy != nil || store.planned.isEmpty)
    }
}

/// Drawn by hand: AppKit's prominent bezel goes grey whenever the app is inactive.
private struct ProminentButtonStyle: ButtonStyle {
    /// Keeps the accent look while disabled, for work in progress.
    var active = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let lit = isEnabled || active
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            .frame(height: 32)
            .background(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(configuration.isPressed ? 0.15 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FooterView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        HStack(spacing: 12) {
            if let run = store.lastRun {
                Stat(symbol: "clock.arrow.circlepath", text: Format.ago(run.finishedAt))
                    .help("Last run \(Format.absolute(run.finishedAt))")
                Stat(symbol: "arrow.down", text: Format.bytes(max(run.freeBytesAfter - run.freeBytesBefore, 0)))
                    .help("Freed by the last run")
            }
            if let next = store.nextRun {
                let s = Format.span(next.timeIntervalSinceNow)
                Stat(symbol: "timer", text: s == "now" ? "soon" : "in \(s)")
                    .help("Next run \(Format.absolute(next))")
            } else {
                Stat(symbol: "pause.circle", text: "paused")
            }
            Spacer()
            Button { store.update { $0.paused.toggle() } } label: {
                Image(systemName: store.config.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(store.config.paused ? "Resume scheduled runs" : "Pause scheduled runs")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct Stat: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text).monospacedDigit()
        }
    }
}
