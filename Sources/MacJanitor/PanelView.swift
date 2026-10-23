import AppKit
import JanitorCore
import ServiceManagement
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView()
            if let problem = store.problem {
                ProblemBanner(text: problem) { store.problem = nil }
            }
            Divider()
            ReportSection()
            if store.awaitingConfirmation, let preview = store.preview {
                ConfirmBanner(preview: preview)
            }
            Divider()
            ControlsView()
        }
        .padding(14)
        .frame(width: 440)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: store.isLowDisk ? "externaldrive.badge.exclamationmark" : "internaldrive")
                    .foregroundStyle(store.isLowDisk ? .red : .secondary)
                Text("\(Format.bytes(store.freeBytes)) free")
                    .font(.headline)
                    .foregroundStyle(store.isLowDisk ? .red : .primary)
                if store.isLowDisk {
                    Text("below \(Format.bytes(Store.lowDiskBytes))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                if let busy = store.busy {
                    ProgressView().controlSize(.small)
                    Text(busy == .running ? "Cleaning up..." : "Previewing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let run = store.lastRun {
                let delta = run.freeBytesAfter - run.freeBytesBefore
                Text("Last run \(Format.relative(run.finishedAt))")
                    .font(.callout)
                    .help(Format.absolute(run.finishedAt))
                Text((delta >= 0 ? "Freed \(Format.bytes(delta))" : "Free space fell \(Format.bytes(-delta))")
                    + " on disk, \(Format.bytes(run.bytes(.removed))) measured across \(run.count(.removed)) removed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if run.count(.failed) > 0 {
                    Text("\(run.count(.failed)) failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ErrorList(errors: run.errors)
            } else {
                Text("No run recorded yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ErrorList: View {
    let errors: [String]

    var body: some View {
        ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

private struct ProblemBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Report list

private struct ReportSection: View {
    @EnvironmentObject private var store: Store
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let report = store.preview ?? store.lastRun
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if store.preview != nil {
                    Label("Preview - nothing deleted yet", systemImage: "eye")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Show last run") { store.dismissPreview() }
                        .buttonStyle(.link)
                        .disabled(store.busy != nil)
                } else {
                    Text("Last run actions").font(.subheadline.bold())
                }
            }
            if let report {
                if store.preview != nil { ErrorList(errors: report.errors) }
                // A ScrollView in a MenuBarExtra window collapses to almost nothing
                // unless given a height, so it is sized to its content up to a cap.
                ScrollView {
                    ReportList(report: report)
                        .background(GeometryReader { geo in
                            Color.clear
                                .onAppear { listHeight = geo.size.height }
                                .onChange(of: geo.size.height) { listHeight = $0 }
                        })
                }
                .frame(height: min(listHeight, 320))
            } else {
                Text("Press Preview to see what would be cleaned up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReportList: View {
    let report: Report
    @State private var showSkips = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.actions.isEmpty {
                Text(report.dryRun ? "Nothing to clean up." : "Nothing was removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(JanitorCore.Category.allCases, id: \.self) { category in
                let actions = report.actions.filter { $0.category == category }
                if !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(category.title) (\(Format.bytes(actions.reduce(0) { $0 + $1.bytes })))")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(actions) { ActionRow(action: $0) }
                    }
                }
            }
            if !report.skips.isEmpty {
                DisclosureGroup("Skipped (\(report.skips.count))", isExpanded: $showSkips) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.skips) { SkipRow(skip: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
    }
}

private struct ActionRow: View {
    let action: Action

    var body: some View {
        let failed = action.status == .failed
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(failed ? .red : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.path(action.target))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(action.target)
                Text(action.reason)
                    .font(.caption)
                    .foregroundStyle(failed ? .red : .secondary)
                if let error = action.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let salvage = action.salvage {
                    Text("Salvaged to \(Format.path(salvage))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(action.bytes)).font(.callout).monospacedDigit()
                Text(statusText).font(.caption).foregroundStyle(failed ? .red : .secondary)
            }
        }
        .foregroundStyle(failed ? .red : .primary)
    }

    private var icon: String {
        switch action.status {
        case .planned: return "circle.dashed"
        case .removed: return "checkmark.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusText: String {
        switch action.status {
        case .planned: return "will remove"
        case .removed: return "removed"
        case .failed: return "failed"
        }
    }
}

private struct SkipRow: View {
    let skip: Skip

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(skip.category.title): \(Format.path(skip.target))")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(skip.target)
            Text(skip.reason).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private struct ConfirmBanner: View {
    @EnvironmentObject private var store: Store
    let preview: Report

    var body: some View {
        let count = preview.count(.planned)
        VStack(alignment: .leading, spacing: 6) {
            Text(count == 0
                 ? "The preview found nothing to remove. Run anyway?"
                 : "Remove \(count) item\(count == 1 ? "" : "s") (\(Format.bytes(preview.bytes(.planned)))) listed above?")
                .font(.callout.bold())
            HStack {
                Spacer()
                Button("Cancel") { store.cancelRun() }
                    .keyboardShortcut(.cancelAction)
                Button(count == 0 ? "Run" : "Remove") { Task { await store.confirmRun() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Controls

private struct ControlsView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let busy = store.busy != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Preview") { Task { await store.runPreview() } }
                Button("Run now...") { Task { await store.requestRun() } }
                Spacer()
                Button("Open log") { store.openLog() }
            }
            .disabled(busy)

            Toggle("Pause automatic runs", isOn: Binding(
                get: { store.paused },
                set: { store.setPaused($0) }
            ))
            .disabled(busy)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Launch at login", isOn: Binding(
                    get: { store.loginStatus == .enabled || store.loginStatus == .requiresApproval },
                    set: { store.setLaunchAtLogin($0) }
                ))
                .disabled(busy)
                LoginStatusNote()
            }

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .disabled(busy)
            }
        }
    }
}

private struct LoginStatusNote: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        if let problem = store.loginProblem {
            Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        switch store.loginStatus {
        case .requiresApproval:
            HStack(spacing: 4) {
                Text("Needs approval in Login Items.").font(.caption).foregroundStyle(.orange)
                Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        default:
            EmptyView()
        }
    }
}
