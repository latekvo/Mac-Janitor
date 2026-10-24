import AppKit
import JanitorCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { store.closeSettings() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Back")
                Text("Settings").font(.headline)
                Spacer()
            }
            .padding(.bottom, 6)

            if let problem = store.problem {
                ProblemBanner(text: problem) { store.problem = nil }
                    .padding(.vertical, 4)
            }

            SettingsSection("Schedule") {
                StepperRow(symbol: "clock", label: "Every", value: store.binding(\.intervalHours),
                           range: 1...48, unit: "h")
                StepperRow(symbol: "internaldrive", label: "Run early below", value: store.binding(\.lowDiskGB),
                           range: 5...200, step: 5, unit: " GB")
            }

            SettingsSection("Remove after") {
                StepperRow(symbol: JanitorCore.Category.nodeModules.symbol, label: "node_modules idle",
                           value: store.binding(\.nodeModulesIdleDays))
                StepperRow(symbol: JanitorCore.Category.worktree.symbol, label: "Merged worktree",
                           value: store.binding(\.mergedIdleDays), range: 0...365)
                StepperRow(symbol: JanitorCore.Category.worktree.symbol, label: "Worktree with open PR",
                           value: store.binding(\.openPRIdleDays))
                StepperRow(symbol: JanitorCore.Category.worktree.symbol, label: "Abandoned worktree",
                           value: store.binding(\.abandonedIdleDays))
                StepperRow(symbol: JanitorCore.Category.dockerImage.symbol, label: "Docker image unused",
                           value: store.binding(\.dockerImageUnusedDays))
                StepperRow(symbol: JanitorCore.Category.avd.symbol, label: "Emulator unused",
                           value: store.binding(\.avdUnusedDays))
                StepperRow(symbol: JanitorCore.Category.scratchpad.symbol, label: "Scratchpad idle",
                           value: store.binding(\.scratchpadIdleDays))
            }

            SettingsSection("Repos", help: "Worktrees of each repo, plus every folder in <repo>-worktrees, are managed",
                    action: ("plus", "Add repo", store.addRepo)) {
                ForEach(store.config.repos, id: \.self) { repo in
                    ListRow(symbol: "folder", text: Format.path(repo), help: repo) {
                        store.update { $0.repos.removeAll { $0 == repo } }
                    }
                }
            }

            if !store.config.keep.isEmpty {
                SettingsSection("Kept") {
                    ForEach(store.config.keep, id: \.self) { target in
                        ListRow(symbol: "pin.fill", text: (target as NSString).lastPathComponent, help: target) {
                            store.update { $0.keep.removeAll { $0 == target } }
                        }
                    }
                }
            }

            Divider().padding(.vertical, 8)

            LoginRow()
            HStack {
                Button { store.openLog() } label: { Label("Log", systemImage: "doc.text") }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .controlSize(.small)
            .padding(.top, 8)
        }
        .padding(Metrics.inset)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    var help: String?
    var action: (symbol: String, help: String, run: () -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, help: String? = nil, action: (String, String, () -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.action = action.map { (symbol: $0.0, help: $0.1, run: $0.2) }
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help(help ?? "")
                Spacer()
                if let action {
                    Button(action: action.run) { Image(systemName: action.symbol) }
                        .buttonStyle(.borderless)
                        .help(action.help)
                }
            }
            .frame(height: 18)
            .padding(.top, 10)
            .padding(.bottom, 2)
            content
        }
    }
}

private struct StepperRow: View {
    let symbol: String
    let label: String
    let value: Binding<Double>
    var range: ClosedRange<Double> = 1...365
    var step: Double = 1
    var unit = "d"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.icon)
            Text(label)
            Spacer(minLength: 4)
            Text(Format.number(value.wrappedValue) + unit)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Stepper(label, value: value, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
        .font(.callout)
        .frame(height: 24)
    }
}

private struct ListRow: View {
    let symbol: String
    let text: String
    let help: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.icon)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help)
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
        }
        .font(.callout)
        .frame(height: 24)
    }
}

private struct LoginRow: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "power.circle")
                .foregroundStyle(.secondary)
                .frame(width: Metrics.icon)
            Text("Open at login")
            if store.loginStatus == .requiresApproval {
                Button { SMAppService.openSystemSettingsLoginItems() } label: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Needs approval in Login Items; click to open")
            }
            Spacer()
            Toggle("Open at login", isOn: Binding(
                get: { store.loginStatus == .enabled || store.loginStatus == .requiresApproval },
                set: { store.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .font(.callout)
        .frame(height: 24)
    }
}

extension Store {
    func binding<T>(_ key: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: key] }, set: { value in self.update { $0[keyPath: key] = value } })
    }
}
