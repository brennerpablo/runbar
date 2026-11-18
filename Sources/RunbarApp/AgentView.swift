import AppKit
import RunbarCore
import SwiftUI

enum AgentPrompt {
    static func setup(root: String) -> String {
        """
        Set up Runbar for my projects in \(root).

        Read ~/.config/runbar/README.md and edit ~/.config/runbar/config.json following ~/.config/runbar/schema.json. For each app that runs a development server (Next.js, Python APIs, docker compose…), add a service with its folder, its command and a port that doesn't clash with the others. If an app reaches its database through a proxy (cloud-sql-proxy, kubectl port-forward, ssh -L), add the proxy as a "proxy" service and list it in that app's "needs". Keep what's already in the file and run `runbar validate` at the end.
        """
    }

    static func fixError(_ issue: ConfigIssue) -> String {
        let loc = issue.line > 0 ? "line \(issue.line), column \(issue.column)" : "unknown position"
        return "~/.config/runbar/config.json is invalid (\(loc)): \(issue.message). Fix the file following ~/.config/runbar/README.md and run `runbar validate` until no errors remain."
    }
}

struct AgentView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var root = ""
    @ViewState private var copied = false
    @ViewState private var cliMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let your agent set it up")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Runbar reads everything from one JSON file. Any agent that can edit files on your Mac can write the whole configuration, and Runbar reloads as soon as the file changes.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                step(1, "Copy the request") {
                    HStack(spacing: 8) {
                        Text("Projects folder").font(.system(size: 12.5))
                        TextField("~/Documents/repos", text: $root)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: root) { copied = false }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(AgentPrompt.setup(root: root.isEmpty ? model.suggestedRoot : root))
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Pasteboard.copy(AgentPrompt.setup(root: root.isEmpty ? model.suggestedRoot : root))
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy request", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                }

                step(2, "Paste it into your agent") {
                    Text("Claude Code, Codex, Cursor or any other agent with access to your files. It reads README.md, scans the folders and writes config.json.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                step(3, "Check it here") { status }
            }
            .padding(28)
            .frame(width: 580, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 22) {
                sidebarSection("In ~/.config/runbar") {
                    fileRow("config.json", "Your configuration. You, your agent and the app edit the same file.")
                    fileRow("schema.json", "JSON Schema for validation and autocomplete in your editor.")
                    fileRow("README.md", "Instructions written for agents: format, port rules, examples.")
                    Button("Show in Finder") { model.revealConfigDir() }.controlSize(.small)
                }
                sidebarSection("In the terminal") {
                    fileRow("runbar validate", "Checks the file and points to each error by line and column.")
                    fileRow("runbar status --json", "Status, actual port, memory and CPU of each service.")
                    fileRow("runbar start · stop · logs <id>", "Your agent can also start services and read their logs to test its changes.")
                    if let installed = model.cliInstalledPath {
                        Text("Installed at \(Paths.abbreviate(installed))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Install the runbar command") { cliMessage = model.installCLI() }.controlSize(.small)
                    }
                    if let cliMessage {
                        Text(cliMessage).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(width: 300, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.primary.opacity(0.03))
        }
        .frame(minHeight: 600)
        .onAppear { if root.isEmpty { root = model.suggestedRoot } }
    }

    @ViewBuilder
    private var status: some View {
        if let issue = model.configError {
            VStack(alignment: .leading, spacing: 8) {
                Label("config.json has an error", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.rbWarn)
                Text("\(issue.location.isEmpty ? "" : issue.location + ": ")\(issue.message)")
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy error for your agent") { Pasteboard.copy(AgentPrompt.fixError(issue)) }
                    Button("Open config.json") { model.openConfigFile() }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.rbOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(Color.rbGreen).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("config.json is valid").font(.system(size: 13, weight: .semibold))
                        Text(validLine).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open config.json") { model.openConfigFile() }.controlSize(.small)
                }
                ForEach(model.configWarnings.prefix(4), id: \.description) { w in
                    Text("warning: \(w.message)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.rbWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.rbGreen.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var validLine: String {
        let s = model.config.services.count
        let p = model.config.projects.count
        let when = model.configLoadedAt.map { " · read at \(Format.clock($0))" } ?? ""
        return "\(s) \(s == 1 ? "service" : "services") in \(p) \(p == 1 ? "project" : "projects")\(when)"
    }

    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold)).padding(.top, 3)
                content()
            }
        }
    }

    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func fileRow(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
