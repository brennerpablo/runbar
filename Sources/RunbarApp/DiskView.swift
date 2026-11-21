import AppKit
import RunbarCore
import SwiftUI

// MARK: - Panel (Disk tab)

/// What dependencies and build output take in each project, with Clear / Reinstall / Delete.
struct DiskPanel: View {
    let query: String
    /// Open projects. The panel holds them, so its Collapse all reaches them and they stay put across tabs.
    @Binding var expanded: Set<String>
    /// The largest project has been opened, once.
    @Binding var opened: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let disk = DiskModel.shared
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = filtered(disk.projects, q)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(disk.results) { DiskResultCard(result: $0) }
            if !disk.hasMeasured {
                measuring(disk)
            } else {
                if q.isEmpty, disk.total > 0 { DiskSummary() }
                ForEach(shown, id: \.0.id) { project, items in
                    ProjectDiskCard(
                        project: project, items: items,
                        expanded: !q.isEmpty || expanded.contains(project.id),
                        scanning: disk.scanning.contains(project.id)
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            if expanded.contains(project.id) { expanded.remove(project.id) } else { expanded.insert(project.id) }
                        }
                    }
                }
                if shown.isEmpty {
                    Text(q.isEmpty ? "Nothing to clean in your projects." : "No matching folders.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.rbText2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
            }
        }
        .onAppear(perform: openLargest)
        .onChange(of: disk.projects.first?.id) { openLargest() }
    }

    /// The largest project starts open, once.
    private func openLargest() {
        guard !opened, let first = DiskModel.shared.projects.first(where: { $0.total > 0 }) else { return }
        opened = true
        expanded.insert(first.id)
    }

    private func filtered(_ projects: [ProjectDisk], _ q: String) -> [(ProjectDisk, [DiskItem])] {
        projects.compactMap { project in
            guard project.total > 0 else { return nil }
            if q.isEmpty || project.name.lowercased().contains(q) { return (project, project.items) }
            let items = project.items.filter {
                "\($0.name) \($0.folder) \($0.serviceID ?? "")".lowercased().contains(q)
            }
            return items.isEmpty ? nil : (project, items)
        }
    }

    private func measuring(_ disk: DiskModel) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(AppModel.shared.config.projects.enumerated()), id: \.element.id) { index, project in
                if index > 0 { Hairline() }
                HStack(spacing: 8) {
                    if disk.scanning.contains(project.id) {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.rbLive).frame(width: 14)
                    }
                    Text(project.name).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text(disk.scanning.contains(project.id) ? "measuring…" : "waiting")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.rbText3)
                }
                .padding(.horizontal, Layout.rowInset)
                .frame(height: 38)
            }
        }
        .rbCard(theme)
    }
}

/// Totals by kind across every project, and the one big action.
private struct DiskSummary: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let disk = DiskModel.shared
        let build = disk.bytes(.build)
        let measured = disk.projects.filter { $0.total > 0 }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Format.memory(disk.total)) in \(measured) \(measured == 1 ? "project" : "projects")")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                if let free = disk.freeBytes {
                    Text("\(DiskText.roundedSize(free)) free on this Mac")
                        .font(.system(size: 11.5))
                        .foregroundStyle(disk.lowOnSpace ? Color.rbWarn : Color.rbText2)
                }
            }
            StackedBar(parts: [build, disk.bytes(.dependencies), disk.bytes(.tools)], height: 8)
            VStack(spacing: 6) {
                legend(.rbLiveFill, "Build output", ".next, .turbo · rebuilt on next start", build)
                legend(.rbDepsBar, "Dependencies", "node_modules, .venv", disk.bytes(.dependencies))
                legend(.rbToolsBar, "Tool caches", ".mypy_cache, .pytest_cache, .ruff_cache", disk.bytes(.tools))
            }
            if build > 0 { buildAction(disk, build) }
        }
        .padding(12)
        .rbCard(theme)
    }

    private func legend(_ color: Color, _ name: String, _ note: String, _ bytes: UInt64) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text(name).font(.system(size: 12)).fixedSize()
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(Format.memory(bytes)).font(.system(size: 11.5, weight: .medium, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func buildAction(_ disk: DiskModel, _ build: UInt64) -> some View {
        let items = disk.buildItems
        let busy = items.filter { disk.jobs[$0.id] != nil }.count
        if busy > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Clearing build output · \(busy) \(busy == 1 ? "folder" : "folders") left")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText2)
            }
            .frame(height: 32)
        } else if disk.confirming == DiskModel.allBuildID {
            AllBuildConfirm(items: items, total: build)
        } else {
            Button {
                disk.confirming = DiskModel.allBuildID
            } label: {
                Text("Clear all build output · \(Format.memory(build))").frame(maxWidth: .infinity)
            }
            .rbButton(theme, prominent: true)
        }
    }
}

private struct AllBuildConfirm: View {
    let items: [DiskItem]
    let total: UInt64
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model

    var body: some View {
        let disk = DiskModel.shared
        let running = Set(items.flatMap { disk.servicesUsing($0).map(\.id) })
        let top = items.prefix(3)
        let rest = items.dropFirst(3)
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 5) {
                ForEach(Array(top)) { item in
                    HStack(spacing: 8) {
                        OwnerDot(serviceID: item.serviceID)
                        (Text(DiskModel.place(of: item)) + Text(" · \(item.name)").foregroundStyle(Color.rbText3))
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.memory(item.bytes)).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    }
                }
                if !rest.isEmpty {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 6, height: 6)
                        Text("\(rest.count) more\(rest.contains(where: \.worktree) ? ", including worktrees" : "")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.rbText3)
                        Spacer(minLength: 4)
                        Text(Format.memory(rest.reduce(0) { $0 + $1.bytes }))
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.rbText2)
                    }
                }
            }
            Text(running.isEmpty
                 ? "Each one is rebuilt the next time its project builds or starts."
                 : "\(running.count) running \(running.count == 1 ? "service is" : "services are") stopped, cleared and started again. Folders outside Runbar services are only cleared.")
                .font(.system(size: 12))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Clear \(Format.memory(total))") { disk.clearAllBuild() }.rbButton(theme, prominent: true)
                Button("Cancel") { disk.confirming = nil }.rbButton(theme)
            }
            .controlSize(.regular)
        }
    }
}

/// One project: name, total and a bar by kind; open, one row per folder.
private struct ProjectDiskCard: View {
    let project: ProjectDisk
    let items: [DiskItem]
    let expanded: Bool
    let scanning: Bool
    let toggle: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        DisclosureChevron(open: expanded)
                        Text(project.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if project.worktreeCount > 0 {
                            let wt = project.worktreeBytes
                            Text("\(project.worktreeCount) \(project.worktreeCount == 1 ? "worktree" : "worktrees")\(wt > 0 ? " · \(Format.memory(wt))" : "")")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.rbText3)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if scanning {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                        }
                        Text(Format.memory(project.total)).font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    StackedBar(parts: [project.bytes(.build), project.bytes(.dependencies), project.bytes(.tools)], height: 4)
                }
                .padding(.horizontal, Layout.rowInset)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(project.name), \(Format.memory(project.total))")
            .accessibilityHint(expanded ? "Collapse" : "Expand")

            if expanded {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Hairline().padding(.leading, index == 0 ? 0 : Layout.rowInset)
                    DiskItemRow(item: item)
                }
            }
        }
        .rbCard(theme)
    }
}

// MARK: - Rows

/// A folder with its size and action; it opens into the confirmation, and shows the job while it runs.
struct DiskItemRow: View {
    let item: DiskItem
    /// In the service detail the service name is implied.
    var showOwner = true
    @Environment(\.theme) private var theme

    var body: some View {
        let disk = DiskModel.shared
        let action = disk.primaryAction(for: item)
        VStack(alignment: .leading, spacing: 0) {
            if let job = disk.jobs[item.id] {
                DiskJobView(job: job)
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(item.category == .tools ? .system(size: 12.5, weight: .medium) : .system(size: 12.5, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if showOwner { OwnerDot(serviceID: item.serviceID) }
                            Text(DiskText.subtitle(item, showOwner: showOwner))
                                .font(.system(size: 11))
                                .foregroundStyle(item.serviceID == nil && item.category == .dependencies ? Color.rbText3 : Color.rbText2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(Format.memory(item.bytes))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .frame(width: 62, alignment: .trailing)
                    Button {
                        disk.confirming = disk.confirming == item.id ? nil : item.id
                    } label: {
                        Text(DiskText.actionLabel(action)).frame(minWidth: 54)
                    }
                    .rbButton(theme)
                    .controlSize(.small)
                    .accessibilityLabel("\(DiskText.actionLabel(action)) \(item.name) in \(DiskModel.place(of: item))")
                }
                .padding(.leading, Layout.rowInset)
                .padding(.trailing, 9)
                .padding(.vertical, 7)
                .frame(minHeight: 50)
                if disk.confirming == item.id {
                    DiskConfirm(item: item, action: action)
                }
            }
        }
    }
}

private struct DiskConfirm: View {
    let item: DiskItem
    let action: DiskAction
    @Environment(\.theme) private var theme

    var body: some View {
        let disk = DiskModel.shared
        let running = disk.servicesUsing(item).map(\.id)
        VStack(alignment: .leading, spacing: 10) {
            Text(DiskText.confirm(item, action, running: running))
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(action == .delete ? Color.rbWarn : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if action == .reinstall, let command = item.install {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("$").foregroundStyle(Color.rbText3)
                    Text(command).lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer(minLength: 4)
                    if let source = item.installSource {
                        Text("from \(source)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.rbText3)
                            .fixedSize()
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.rbControl, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            HStack(spacing: 8) {
                Button(DiskText.confirmLabel(item, action)) { disk.perform(action, on: item) }
                    .buttonStyle(RBButtonStyle(prominent: true, warn: action == .delete))
                Button("Cancel") { disk.confirming = nil }.rbButton(theme)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, Layout.rowInset)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }
}

/// Steps of a running job: stop, delete, install, start.
private struct DiskJobView: View {
    let job: DiskJob
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.item.name)
                        .font(job.item.category == .tools ? .system(size: 12.5, weight: .medium) : .system(size: 12.5, weight: .medium, design: .monospaced))
                    Text("\(DiskModel.place(of: job.item)) · \(DiskText.doing(job.action))")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.rbText2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if job.step == .installing {
                    Button("Cancel") { DiskModel.shared.cancel(job.item.id) }.rbButton(theme).controlSize(.small)
                }
            }
            .frame(minHeight: 36)
            if job.step == .waiting {
                Text("Waiting for the folders before it…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText3)
            } else {
                ForEach(job.steps, id: \.self) { step in
                    stepRow(step)
                    if step == .installing, job.step == .installing, let line = job.lastLine {
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(white: 0.62))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.rbLogBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .padding(.leading, Layout.rowInset)
        .padding(.trailing, 9)
        .padding(.top, 7)
        .padding(.bottom, 12)
    }

    private func stepRow(_ step: DiskJob.Step) -> some View {
        let done = step < job.step
        let current = step == job.step
        return HStack(spacing: 8) {
            Group {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.rbLive)
                } else if current {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Circle().strokeBorder(Color.rbRing, lineWidth: 1.5).frame(width: 9, height: 9)
                }
            }
            .frame(width: 14, height: 14)
            Text(DiskText.step(step, job: job, done: done, current: current))
                .font(.system(size: 12, weight: current ? .medium : .regular))
                .foregroundStyle(current ? Color.primary : (done ? Color.rbText2 : Color.rbText3))
                .lineLimit(1)
            Spacer(minLength: 4)
            if step == .deleting {
                Text(Format.memory(job.item.bytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.rbText3)
            } else if step == .installing, current {
                TimelineView(.periodic(from: job.stepStartedAt, by: 1)) { context in
                    Text(DiskText.clock(context.date.timeIntervalSince(job.stepStartedAt)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.rbText2)
                }
            }
        }
    }
}

/// What happened, at the top of the Disk view (and in the service's detail).
struct DiskResultCard: View {
    let result: DiskResult
    @Environment(\.theme) private var theme

    var body: some View {
        let disk = DiskModel.shared
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: result.ok ? "checkmark" : "exclamationmark.triangle")
                    .font(.system(size: result.ok ? 12 : 12.5, weight: .bold))
                    .foregroundStyle(result.ok ? Color.rbLive : Color.rbWarn)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(size: 12.5, weight: result.ok ? .medium : .semibold))
                        .foregroundStyle(result.ok ? Color.primary : Color.rbWarn)
                    if result.ok {
                        Text(result.detail).font(.system(size: 11)).foregroundStyle(Color.rbText2).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if result.ok, let free = disk.freeBytes, result.title.hasPrefix("Freed") {
                    Text("\(Format.memory(free)) free")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.rbLive)
                }
                Button { disk.dismiss(result.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Dismiss")
            }
            if !result.ok {
                if let line = result.lastLine {
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.54, blue: 0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.rbLogBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(result.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbWarn)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let item = result.retry, let action = result.retryAction {
                        Button("Try again") {
                            disk.dismiss(result.id)
                            disk.perform(action, on: item)
                        }
                    }
                    if let url = result.logURL {
                        Button("Open log") { NSWorkspace.shared.open(url) }
                    }
                }
                .rbButton(theme)
                .controlSize(.small)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(result.ok ? Color.rbLiveSoft : Color.rbWarnSoft, in: shape)
        .overlay(shape.strokeBorder(result.ok ? Color.rbLiveFill.opacity(0.28) : Color.rbWarnBorder))
    }
}

// MARK: - Service detail

/// The service's own dependencies and build output, below its folder.
struct DiskSection: View {
    let runtime: ServiceRuntime
    @Environment(\.theme) private var theme

    var body: some View {
        let disk = DiskModel.shared
        let items = disk.items(forService: runtime.id)
        let results = disk.results.filter { $0.serviceID == runtime.id }
        if !disk.hasMeasured {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Disk").padding(.leading, 2)
                HStack(spacing: 8) {
                    Text(disk.isScanning ? "Measuring your projects…" : "Not measured yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbText2)
                    Spacer(minLength: 4)
                    if !disk.isScanning {
                        Button("Measure") { disk.scan() }.rbButton(theme).controlSize(.small)
                    }
                }
                .padding(.leading, Layout.rowInset)
                .padding(.trailing, 7)
                .frame(minHeight: 40)
                .rbCard(theme, radius: 12)
            }
        } else if !items.isEmpty || !results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    SectionLabel(text: "Disk").padding(.leading, 2)
                    Spacer()
                    Text("\(Format.memory(items.reduce(0) { $0 + $1.bytes })) · \(DiskText.scanned(disk.scannedAt))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.rbText3)
                        .padding(.trailing, 2)
                }
                .frame(height: 18)
                ForEach(results) { DiskResultCard(result: $0) }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Hairline().padding(.leading, Layout.rowInset) }
                            DiskItemRow(item: item, showOwner: false)
                        }
                        if runtime.isRunningAnywhere {
                            Hairline()
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.rbText3)
                                Text("Clearing or reinstalling stops \(runtime.id) first and starts it again when done.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.rbText3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, Layout.rowInset)
                            .padding(.vertical, 9)
                        }
                    }
                    .rbCard(theme, radius: 12)
                }
            }
        }
    }
}

// MARK: - Pieces

/// Bar split by kind: build output (green), dependencies, tool caches.
struct StackedBar: View {
    let parts: [UInt64]
    var height: CGFloat = 8
    private let colors: [Color] = [.rbLiveFill, .rbDepsBar, .rbToolsBar]

    var body: some View {
        let total = max(parts.reduce(0, +), 1)
        let visible = parts.enumerated().filter { $0.element > 0 }
        GeometryReader { geo in
            let gaps = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(visible, id: \.offset) { index, bytes in
                    colors[index].frame(width: max(2, (geo.size.width - gaps) * CGFloat(bytes) / CGFloat(total)))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct OwnerDot: View {
    let serviceID: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let serviceID, let rt = model.runtimes[serviceID] {
            StatusDot(dot: rt.isRunningAnywhere ? .running : .stopped, size: 6, halo: false)
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.rbHairline).frame(height: 1)
    }
}

enum DiskText {
    static func actionLabel(_ action: DiskAction) -> String {
        switch action {
        case .clear: return "Clear"
        case .reinstall: return "Reinstall"
        case .delete: return "Delete"
        }
    }

    static func doing(_ action: DiskAction) -> String {
        switch action {
        case .clear: return "clearing"
        case .reinstall: return "reinstalling"
        case .delete: return "deleting"
        }
    }

    static func subtitle(_ item: DiskItem, showOwner: Bool) -> String {
        let owner = showOwner ? DiskModel.place(of: item) + (item.worktree && item.serviceID == nil ? " · worktree" : "") : nil
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }
        switch item.category {
        case .tools:
            let names = Set(item.paths.map { ($0 as NSString).lastPathComponent }).sorted().joined(separator: ", ")
            return join([item.detail, names])
        case .build:
            return showOwner ? join([owner, "build output"]) : "Build output · rebuilt on next start"
        case .dependencies:
            guard item.serviceID != nil else { return join([owner, item.worktree ? nil : "not a service"]) }
            // The lockfile shows in the confirmation; here, just how it comes back.
            let how = item.detail ?? item.install.map(DiskModel.shortCommand) ?? "no lockfile"
            return showOwner ? join([owner, how]) : join(["Dependencies", how])
        }
    }

    static func confirm(_ item: DiskItem, _ action: DiskAction, running: [String]) -> String {
        let who = DiskModel.list(running)
        let isAre = running.count == 1 ? "is" : "are"
        switch action {
        case .reinstall:
            return running.isEmpty
                ? "Runbar deletes \(item.name) and runs the install."
                : "Runbar stops \(who), deletes \(item.name) and runs the install. \(who) \(running.count == 1 ? "starts" : "start") again when it finishes."
        case .clear:
            if item.category == .tools {
                return "Linters and test runners recreate these caches the next time they run."
            }
            let base = item.name == ".next"
                ? "Next.js rebuilds it on the next start, so the first page loads take longer."
                : "It's rebuilt the next time the project builds."
            return running.isEmpty ? base : base + " \(who) \(isAre) running: Runbar stops \(running.count == 1 ? "it" : "them"), clears \(item.name) and starts \(running.count == 1 ? "it" : "them") again."
        case .delete:
            let base = item.serviceID == nil
                ? "This folder isn't part of a Runbar service, so Runbar can't reinstall it."
                : "Runbar found no lockfile to reinstall it from."
            let stop = running.isEmpty ? "" : " \(who) \(isAre) stopped first."
            return base + " It's deleted permanently, not moved to the Trash." + stop
        }
    }

    static func confirmLabel(_ item: DiskItem, _ action: DiskAction) -> String {
        switch action {
        case .reinstall: return "Reinstall"
        case .clear: return "Clear \(Format.memory(item.bytes))"
        case .delete: return "Delete \(Format.memory(item.bytes))"
        }
    }

    static func step(_ step: DiskJob.Step, job: DiskJob, done: Bool, current: Bool) -> String {
        let who = DiskModel.list(job.services)
        let name = job.item.name
        let install = job.item.install.map(DiskModel.shortCommand) ?? "install"
        switch step {
        case .waiting: return "Waiting"
        case .stopping: return done ? "Stopped \(who)" : current ? "Stopping \(who)" : "Stop \(who)"
        case .deleting: return done ? "Deleted \(name)" : current ? "Deleting \(name)" : "Delete \(name)"
        case .installing: return done ? "Ran \(install)" : current ? "Running \(install)" : "Run \(install)"
        case .starting: return done || current ? "Starting \(who)" : "Start \(who)"
        }
    }

    /// "30 GB" from 10 GB up, where the decimal adds nothing at a glance.
    static func roundedSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 10 ? "\(Int(gb.rounded())) GB" : Format.memory(bytes)
    }

    static func clock(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func scanned(_ date: Date?) -> String {
        guard let date else { return "not measured yet" }
        let ago = Format.ago(date)
        return ago == "now" ? "measured just now" : "measured \(ago)"
    }
}
