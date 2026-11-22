import SwiftUI

/// Settings → General → Updates.
struct UpdateSettingsSection: View {
    @State private var updater = Updater.shared

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updater.autoCheck)
            Toggle("Install updates automatically", isOn: $updater.autoInstall)
                .disabled(!updater.autoCheck)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hangtime \(Updater.currentVersion)")
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                Spacer()
                actionButton
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Installed via \(updater.methodDescription). Your settings and widgets are kept when updating.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch updater.phase {
        case .checking:
            ProgressView().controlSize(.small)
        case .installing:
            ProgressView().controlSize(.small)
        case .available:
            Button("Install \(updater.latest?.version ?? "")") { Task { await updater.install() } }
                .buttonStyle(.borderedProminent)
        default:
            Button("Check Now") { Task { await updater.check(userInitiated: true) } }
        }
    }

    private var statusIsError: Bool { if case .failed = updater.phase { true } else { false } }

    private var statusLine: String {
        switch updater.phase {
        case .checking: return "Checking…"
        case .upToDate: return "You're up to date."
        case .available: return "Version \(updater.latest?.version ?? "") is available."
        case .installing(let s): return s
        case .failed(let e): return e
        case .idle:
            if let last = updater.lastCheck {
                return "Last checked \(last.formatted(.relative(presentation: .named)))."
            }
            return "Not checked yet."
        }
    }
}

/// A panel row shown only while an update is available or being installed.
struct UpdateMenuRow: View {
    @State private var updater = Updater.shared

    var body: some View {
        switch updater.phase {
        case .available where updater.updateAvailable:
            MenuRow(title: "Install Update \(updater.latest?.version ?? "")", systemImage: "arrow.down.circle") {
                Task { await updater.install() }
            }
        case .installing(let s):
            MenuRow(title: s, systemImage: "arrow.down.circle", busy: true) {}
                .disabled(true)
        case .failed(let e) where updater.updateAvailable:
            MenuRow(title: "Update failed. Try Again", systemImage: "exclamationmark.triangle") {
                Task { await updater.install() }
            }
            .help(e)
        default:
            EmptyView()
        }
    }
}
