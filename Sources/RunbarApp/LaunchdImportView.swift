import AppKit
import RunbarCore
import SwiftUI

/// Moves a launchd job (a LaunchAgent that keeps a proxy alive, a `brew services` server) into
/// config.json: from then on Runbar opens it when needed instead of launchd keeping it up all day.
struct LaunchdImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let listener: Listener
    let job: LaunchdJob
    /// nil when cancelled; otherwise the new service's id, to show its detail.
    let done: (String?) -> Void

    @ViewState private var name = ""
    @ViewState private var projectID = ""
    @ViewState private var idle = "15m"
    @ViewState private var openWith: Set<String> = []
    @ViewState private var working = false
    @ViewState private var failure: String?
    @ViewState private var prepared = false

    private var command: String { job.command(port: listener.port) }
    private var isProxy: Bool { ProxyTool.detect(command) != .other }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button { done(nil) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Services")
                    }
                }
                .buttonStyle(TextButtonStyle(size: 13))
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                chip
            }
            .padding(.leading, 6)
            .padding(.trailing, theme.gutter)
            .padding(.top, 12)

            AdaptiveScroll(maxHeight: 700) {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Move into Runbar")
                            .font(.system(size: 19, weight: .semibold))
                            .tracking(-0.2)
                        Text("\(listener.name) on :\(String(listener.port)), started by \(job.label)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.rbText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if job.keepAlive || job.runAtLoad {
                        Banner(text: launchdText)
                    }
                    form
                    whatHappens
                    if let failure {
                        Banner(text: failure)
                    }
                    HStack(spacing: 8) {
                        Button {
                            submit()
                        } label: {
                            HStack(spacing: 6) {
                                if working { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
                                Text("Move into Runbar")
                            }
                        }
                        .rbButton(theme, prominent: true)
                        .disabled(working || !RunbarConfig.isValidID(name) || projectID.isEmpty)
                        Button("Cancel") { done(nil) }.rbButton(theme)
                    }
                    .controlSize(.regular)
                }
                .padding(.horizontal, theme.gutter)
                .padding(.top, 10)
                .padding(.bottom, theme.gutter)
            }
        }
        .onAppear(perform: prepare)
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
            Text(job.keepAlive ? "Kept alive by launchd" : "launchd job")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(job.keepAlive ? Color.rbWarn : Color.rbText2)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(job.keepAlive ? Color.rbWarnSoft : Color.rbControl, in: Capsule())
    }

    private var launchdText: String {
        var parts: [String] = []
        if job.keepAlive { parts.append("Kill doesn't stick here: the plist has KeepAlive, so launchd starts it again within seconds.") }
        if job.runAtLoad { parts.append("It also starts at login, so :\(listener.port) is open all day.") }
        return parts.joined(separator: " ")
    }

    // MARK: - Form

    private var form: some View {
        let projects = model.config.projects
        let services = projects.first { $0.id == projectID }?.services.filter { !$0.isProxy } ?? []
        return VStack(alignment: .leading, spacing: 0) {
            field("Name") {
                TextField("fundsys-db", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Color.rbControl, in: RoundedRectangle(cornerRadius: theme.pillRadius, style: .continuous))
                    .accessibilityLabel("Name")
            }
            divider
            field("Project") {
                Picker("Project", selection: $projectID) {
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            divider
            field("Command") {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.rbText2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            divider
            field("Port") {
                Text(":\(String(listener.port))").font(.system(size: 12, design: .monospaced))
            }
            if isProxy {
                divider
                field("Opens with", alignTop: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        if services.isEmpty {
                            Text("This project has no services.").font(.system(size: 12)).foregroundStyle(Color.rbText2)
                        }
                        ForEach(services) { svc in
                            Toggle(isOn: Binding(
                                get: { openWith.contains(svc.id) },
                                set: { on in if on { openWith.insert(svc.id) } else { openWith.remove(svc.id) } }
                            )) {
                                Text(svc.id).font(.system(size: 12))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 2)
                }
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Close when idle").font(.system(size: 12)).foregroundStyle(Color.rbText2)
                    IdleSegments(options: IdleSetting.presets, selection: idle) { idle = $0 }
                }
                .padding(.horizontal, Layout.rowInset)
                .padding(.vertical, 10)
            }
        }
        .rbCard(theme, radius: 12)
        .disabled(working)
    }

    private var divider: some View {
        Rectangle().fill(Color.rbHairline).frame(height: 1)
    }

    private func field<Content: View>(_ label: String, alignTop: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.rbText2)
                .frame(width: 84, alignment: .leading)
                .padding(.top, alignTop ? 3 : 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.rowInset)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
    }

    private var whatHappens: some View {
        let project = model.config.projects.first { $0.id == projectID }?.name ?? "the project"
        let shown = name.isEmpty ? "it" : name
        var steps: [String] = []
        if job.isUserAgent {
            steps.append("Unloads \(job.label) and moves its plist to ~/.config/runbar/launchd/. Moving it back undoes this.")
        } else {
            steps.append("Unloads \(job.label) and turns it off, so it doesn't start at login.")
        }
        steps.append("Adds \(shown) to \(project) in config.json, with the same command.")
        if isProxy {
            let with = openWith.sorted()
            steps.append(":\(String(listener.port)) stays closed until you open it" + (with.isEmpty ? "." : ", or until \(with.joined(separator: " or ")) starts."))
        } else {
            steps.append(":\(String(listener.port)) stays free until you start \(shown) from Runbar.")
        }
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "What happens").padding(.leading, 2)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.rbText3)
                        Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, Layout.rowInset)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rbCard(theme, radius: 12)
        }
    }

    // MARK: - Actions

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let taken = Set(model.config.services.map(\.id))
        name = Self.suggestedName(job, command: command, taken: taken)
        projectID = Self.suggestedProject(job, command: command, projects: model.config.projects) ?? ""
    }

    private func submit() {
        failure = nil
        working = true
        let choice = LaunchdImport(name: name, projectID: projectID, idle: idle, openWith: openWith.sorted())
        model.importLaunchd(job, port: listener.port, choice) { error in
            working = false
            if let error {
                failure = error
                // The config entry may already be there: then the detail shows it.
                if model.runtimes[choice.name] != nil { done(choice.name) }
            } else {
                done(choice.name)
            }
        }
    }

    // MARK: - Guesses

    /// `fundsys-db` for a Cloud SQL instance `fundsys:us-central1:fundsys`; otherwise the label's most
    /// specific word (`homebrew.mxcl.redis` → `redis`).
    static func suggestedName(_ job: LaunchdJob, command: String, taken: Set<String>) -> String {
        var base = ""
        let tool = ProxyTool.detect(command)
        if tool == .cloudSQL || tool == .alloyDB,
           let instance = job.programArguments.last(where: { !$0.hasPrefix("-") && $0.split(separator: ":").count == 3 }),
           let last = instance.split(separator: ":").last?.split(separator: "?").first {
            base = "\(last)-db"
        }
        if base.isEmpty {
            let skip: Set<String> = ["com", "br", "org", "io", "net", "dev", "app", "homebrew", "mxcl", "local", "user", "agent"]
            let parts = job.label.split(separator: ".").map(String.init)
            base = parts.last { !skip.contains($0.lowercased()) && ProxyTool.detect($0) == .other } ?? parts.last ?? "service"
        }
        base = base.lowercased().replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if base.isEmpty { base = "service" }
        var candidate = base
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// The project whose id or name shows up in the job's label or command (the longest match wins).
    static func suggestedProject(_ job: LaunchdJob, command: String, projects: [ProjectConfig]) -> String? {
        let hay = (job.label + " " + command).lowercased()
        let matches = projects.filter { hay.contains($0.id.lowercased()) || hay.contains($0.name.lowercased()) }
        return matches.max { $0.id.count < $1.id.count }?.id ?? projects.first?.id
    }
}
