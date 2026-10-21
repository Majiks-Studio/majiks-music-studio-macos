import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Settings ▸ MCP / API — the human face of the engine's MCP server.
///
/// Everything an agent needs to drive this Studio session, without a terminal:
/// an enable toggle, a Keychain-backed token you can rotate, the port, a LIVE
/// health check (`GET /health` — not just "we called start"), and one-click copy
/// of the `claude mcp add` line.
///
/// The token is never rendered in the clear by default. Reveal is an explicit,
/// momentary act; Copy puts the real value on the pasteboard without ever
/// drawing it.
struct StudioMCPSettingsView: View {
    @StateObject private var model = StudioMCPServerModel.shared

    @State private var revealToken = false
    @State private var portText = ""
    @State private var showRotateConfirm = false
    @State private var copiedLabel: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !model.engineAvailable { mockBuildBanner }
                Divider()
                statusSection
                Divider()
                enableSection
                Divider()
                tokenSection
                Divider()
                connectionSection
                Divider()
                helpSection
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            portText = String(model.activePort)
            Task { await model.probeHealth() }
        }
        .task {
            // Keep the indicator honest while the pane is open: a server that
            // died must not keep showing green.
            while !Task.isCancelled {
                await model.probeHealth()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onDisappear { revealToken = false }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP / API").font(.title2).fontWeight(.semibold)
                Text("Let an agent drive this Studio session — the same 109 tools, the same command bus, the same undo.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.top)
    }

    private var mockBuildBanner: some View {
        Label {
            Text(StudioMCPServerModel.mockBuildReason)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Status", systemImage: "dot.radiowaves.left.and.right")

            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusHeadline).font(.body).fontWeight(.medium)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    Task { await model.probeHealth() }
                } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            if let detail = statusDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The one check that separates "start returned" from "something is
            // actually answering". Shown as its own line so a green toggle can
            // never hide a dead socket.
            HStack(spacing: 6) {
                Image(systemName: healthIcon).foregroundStyle(healthColor)
                Text(healthText).font(.caption).foregroundColor(.secondary)
            }

            if let note = model.note {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Server", systemImage: "power")

            Toggle(isOn: Binding(
                get: { model.isEnabled },
                set: { on in
                    busy = true
                    Task {
                        await model.setEnabled(on)
                        portText = String(model.activePort)
                        busy = false
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable the MCP server")
                    Text("Off by default. Binds 127.0.0.1 only and refuses to start without a token.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!model.engineAvailable || busy)

            HStack(spacing: 8) {
                Text("Port").frame(width: 44, alignment: .leading)
                TextField("8478", text: $portText)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.engineAvailable || busy)
                Button("Apply") { applyPort() }
                    .disabled(!model.engineAvailable || busy || !portChanged)
                Text("Default 8478 — distinct from Majik's DJ (8471), so both can serve at once.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Personal access token", systemImage: "key.fill")

            Text("Stored in your login Keychain, never on disk in the clear and never written to the log. Every request except /health must send it as a bearer token.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(tokenDisplay)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10))
                    .cornerRadius(6)

                Button {
                    revealToken.toggle()
                } label: {
                    Image(systemName: revealToken ? "eye.slash" : "eye")
                }
                .help(revealToken ? "Hide the token" : "Reveal the token")
                .disabled(!model.hasPAT)

                Button {
                    copy(model.storedPAT() ?? "", label: "Token copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy the token")
                .disabled(!model.hasPAT)
            }

            HStack(spacing: 10) {
                if model.hasPAT {
                    Button("Rotate token…") { showRotateConfirm = true }
                        .disabled(busy)
                } else {
                    Button("Generate token") { generate() }
                        .disabled(busy)
                }
                if let copiedLabel {
                    Label(copiedLabel, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .alert("Rotate the access token?", isPresented: $showRotateConfirm) {
                Button("Rotate", role: .destructive) { generate() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Every agent already configured with the current token stops working until you give it the new connection line.")
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Connect an agent", systemImage: "terminal")

            Text(model.connectionLine(revealed: revealToken))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10))
                .cornerRadius(6)

            HStack(spacing: 10) {
                Button {
                    guard let pat = model.storedPAT() else { return }
                    copy(
                        StudioMCPWire.connectionLine(port: model.activePort, token: pat),
                        label: "Connection line copied"
                    )
                } label: {
                    Label("Copy connection line", systemImage: "doc.on.doc")
                }
                .disabled(!model.hasPAT)

                Text("Paste it into a terminal — it registers this running Studio with Claude Code.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Without the UI", systemImage: "chevron.left.forwardslash.chevron.right")
            Text("Launching the app with `\(StudioMCPWire.patFlag) <TOKEN> [\(StudioMCPWire.portFlag) <N>]` starts the server for that run and logs the ready-to-paste connection line. Launch arguments win over this pane and are not written to the Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Full tool reference: docs/MCP_API.md (109 tools across read / perform / manage tiers; manage tools require \"confirm\": true).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: Derived display

    private var statusColor: Color {
        switch model.state {
        case .running: return model.health == .ok ? .green : .yellow
        case .starting: return .yellow
        case .failed: return .red
        case .unavailable: return .orange
        case .off: return .secondary
        }
    }

    private var statusHeadline: String {
        switch model.state {
        case .off: return "Not running"
        case .starting: return "Starting…"
        case .running(let port): return "Running on 127.0.0.1:\(port)\(StudioMCPWire.httpPath)"
        case .failed: return "Failed to start"
        case .unavailable: return "Unavailable in this build"
        }
    }

    private var statusDetail: String? {
        switch model.state {
        case .failed(let why): return why
        case .unavailable(let why): return why
        case .off: return "No token, no server. Enable it above to let an agent drive this session."
        default: return nil
        }
    }

    private var healthIcon: String {
        switch model.health {
        case .ok: return "checkmark.seal.fill"
        case .unreachable: return "xmark.seal.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var healthColor: Color {
        switch model.health {
        case .ok: return .green
        case .unreachable: return model.state.isRunning ? .red : .secondary
        case .unknown: return .secondary
        }
    }

    private var healthText: String {
        switch model.health {
        case .ok:
            return "GET /health answered ok — the server is really listening."
        case .unreachable(let why):
            return model.state.isRunning
                ? "Started, but GET /health did not answer (\(why)). Nothing is serving."
                : "GET /health: \(why)"
        case .unknown:
            return "Health not checked yet."
        }
    }

    private var tokenDisplay: String {
        guard let pat = model.storedPAT() else { return "No token yet" }
        return revealToken ? pat : StudioMCPWire.mask(pat)
    }

    private var portChanged: Bool {
        UInt16(portText.trimmingCharacters(in: .whitespaces)).map { $0 != model.activePort } ?? false
    }

    // MARK: Actions

    private func generate() {
        busy = true
        Task {
            _ = model.regeneratePAT()
            if model.state.isRunning { await model.restart() }
            busy = false
        }
    }

    private func applyPort() {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value > 0 else {
            portText = String(model.activePort)
            return
        }
        busy = true
        Task {
            model.port = value
            if model.isEnabled { await model.restart() }
            portText = String(model.activePort)
            busy = false
        }
    }

    private func copy(_ value: String, label: String) {
        guard !value.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
        copiedLabel = label
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copiedLabel == label { copiedLabel = nil }
        }
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .fontWeight(.semibold)
    }
}
