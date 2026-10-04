import AppKit
import SwiftUI

/// Compositor > MCP Server…: turns the server on, shows how to connect an agent, and which folders it can use.
@MainActor
enum AgentSettingsWindow {
    private static let panel = FloatingPanelController(name: "mcpServer")
    static func show() {
        panel.show(title: String(localized: "MCP Server"), content: AgentSettingsSheet(server: .shared, files: .shared))
    }
}

private struct AgentSettingsSheet: View {
    let server: AgentServer
    let files: AgentFiles
    @State private var portText = ""
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let AI agents such as Cursor, Claude Code or Codex see and edit your open documents. They connect on this Mac only, with the token below, and every change they make shows on the canvas and can be undone.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Allow AI agents to connect", isOn: Binding(get: { server.isEnabled }, set: { server.isEnabled = $0 }))
                Spacer()
                status
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Address").foregroundStyle(.secondary)
                    Text(verbatim: server.endpoint).monospaced().textSelection(.enabled)
                }
                GridRow {
                    Text("Port").foregroundStyle(.secondary)
                    HStack {
                        TextField("", text: $portText).frame(width: 72).onSubmit(applyPort)
                        Button("Apply", action: applyPort).disabled(Int(portText) == server.port)
                    }
                }
                GridRow {
                    Text("Token").foregroundStyle(.secondary)
                    HStack {
                        Text(verbatim: String(server.token.prefix(6)) + "••••••••").monospaced()
                        Button("Copy") { copy(server.token, as: "token") }
                        Button("New Token") { server.regenerateToken() }
                            .help("Agents set up with the old token must be set up again.")
                    }
                }
            }
            Divider()
            Text("Set up an agent").font(.headline)
            HStack {
                Button("Copy Cursor Setup") { copy(cursorSetup, as: "cursor") }
                Button("Copy Claude Code Command") { copy(claudeCommand, as: "claude") }
                Button("Copy Codex Setup") { copy(codexSetup, as: "codex") }
            }
            Text(copied.map(hint) ?? String(localized: "Each button copies what that agent needs, with this address and token."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Folders agents can use").font(.headline)
            Text("Besides your Pictures and Downloads folders and the projects you have open.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(files.folders, id: \.self) { url in
                    HStack {
                        Image(systemName: "folder")
                        Text(verbatim: url.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { files.removeFolder(url) }
                    }
                }
                Button("Add Folder…") { Task { await files.addFolder(window: NSApp.keyWindow) } }
            }
            Divider()
            Text("Recent activity").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if server.activity.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(server.activity) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: entry.failed ? "exclamationmark.triangle" : "checkmark.circle")
                                .foregroundStyle(entry.failed ? .orange : .secondary)
                            Text(entry.date, style: .time).foregroundStyle(.secondary).monospacedDigit()
                            Text(verbatim: entry.tool).monospaced()
                            Text(verbatim: entry.message).foregroundStyle(.secondary).lineLimit(2)
                        }.font(.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 130)
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { portText = String(server.port) }
    }

    @ViewBuilder private var status: some View {
        switch server.state {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .starting:
            Label("Starting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .listening:
            Label(server.clientName.map { String(localized: "On · \($0)") } ?? String(localized: "On"), systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func applyPort() {
        guard let value = Int(portText), (1024...65535).contains(value) else { portText = String(server.port); return }
        server.setPort(value)
    }

    private func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
    }

    private func hint(_ kind: String) -> String {
        switch kind {
        case "cursor": String(localized: "Copied. Add it to ~/.cursor/mcp.json (merge it into \"mcpServers\" if the file has others), then turn on “compositor” in Cursor Settings > MCP.")
        case "claude": String(localized: "Copied. Run it in Terminal, then start Claude Code.")
        case "codex": String(localized: "Copied. Add it to ~/.codex/config.toml, then restart Codex.")
        default: String(localized: "Copied the token.")
        }
    }

    private var cursorSetup: String {
        """
        {
          "mcpServers": {
            "compositor": {
              "url": "\(server.endpoint)",
              "headers": { "Authorization": "Bearer \(server.token)" }
            }
          }
        }
        """
    }
    private var claudeCommand: String {
        "claude mcp add --transport http compositor \(server.endpoint) --header \"Authorization: Bearer \(server.token)\""
    }
    private var codexSetup: String {
        """
        [mcp_servers.compositor]
        url = "\(server.endpoint)"
        http_headers = { "Authorization" = "Bearer \(server.token)" }
        """
    }
}
