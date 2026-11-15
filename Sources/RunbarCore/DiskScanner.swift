import Darwin
import Foundation

/// What a folder Runbar can clean is, and so what cleaning it means.
public enum DiskCategory: String, Sendable, CaseIterable {
    /// Rebuilt by the dev server or the build (`.next`, `.turbo`, `target`…).
    case build
    /// Installed from a lockfile (`node_modules`, `.venv`).
    case dependencies
    /// Recreated by linters and test runners (`.mypy_cache`…).
    case tools

    public var label: String {
        switch self {
        case .build: return "Build output"
        case .dependencies: return "Dependencies"
        case .tools: return "Tool caches"
        }
    }
}

/// A folder (or, for tool caches, a group of folders) inside a project that Runbar can clean.
public struct DiskItem: Sendable, Identifiable, Equatable {
    public var id: String
    /// `.next`, `node_modules`, `.venv`, or "Tool caches" for the group.
    public var name: String
    public var category: DiskCategory
    /// Absolute paths. One, except for the tool caches group.
    public var paths: [String]
    public var bytes: UInt64
    /// Folder that holds it, relative to the project root ("acme-web", "wt-checkout-redesign").
    public var folder: String
    /// Absolute folder that holds it.
    public var parent: String
    /// Service whose own folder (cwd) holds it.
    public var serviceID: String?
    /// Inside a git worktree at the top of the project folder.
    public var worktree: Bool
    /// Command that reinstalls it, and the file it was picked from ("package-lock.json", "config.json").
    public var install: String?
    public var installSource: String?
    /// "Python 3.12" for virtualenvs.
    public var detail: String?
}

public struct ProjectDisk: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var root: String
    /// Largest first.
    public var items: [DiskItem]
    /// Git worktrees at the top of the project folder.
    public var worktreeCount: Int
    /// Leftovers from a delete that didn't finish (`.runbar-deleting-*`).
    public var leftovers: [String]

    public var total: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    public var worktreeBytes: UInt64 { items.filter(\.worktree).reduce(0) { $0 + $1.bytes } }

    public func bytes(_ category: DiskCategory) -> UInt64 {
        items.filter { $0.category == category }.reduce(0) { $0 + $1.bytes }
    }
}

public enum DiskScanner {
    /// Build output folders and the file next to them that proves they are build output.
    /// Generic names (`build`, `dist`, `out`, `.cache`) are left out: they often hold things that can't be rebuilt.
    static let buildMarkers: [String: [String]] = [
        ".next": ["package.json"], ".turbo": ["package.json"], ".nuxt": ["package.json"],
        ".svelte-kit": ["package.json"], ".parcel-cache": ["package.json"], ".vite": ["package.json"],
        ".angular": ["angular.json"],
        "target": ["pom.xml", "Cargo.toml"],
        ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
    ]
    static let toolNames: Set<String> = [".mypy_cache", ".pytest_cache", ".ruff_cache"]
    static let skipNames: Set<String> = [".git", ".hg", ".svn", "__pycache__", ".Trash"]
    static let leftoverPrefix = ".runbar-deleting-"

    /// Measures every cleanable folder under the project's root (or under each service folder when
    /// the project has no root). Reads only; never follows symlinks or leaves the volume.
    public static func scan(project: ProjectConfig, maxDepth: Int = 7) -> ProjectDisk {
        let roots = project.root.map { [standard($0)] } ?? Array(Set(project.services.map { standard($0.cwd) })).sorted()
        let rootForRelative = project.root.map(standard) ?? commonParent(roots)
        var found: [(path: String, name: String, category: DiskCategory)] = []
        var leftovers: [String] = []
        for root in roots {
            walk(root, depth: 0, maxDepth: maxDepth, found: &found, leftovers: &leftovers)
        }

        let fm = FileManager.default
        var worktrees = Set<String>()
        if let top = try? fm.contentsOfDirectory(atPath: rootForRelative) {
            for name in top where isWorktree(rootForRelative + "/" + name) { worktrees.insert(name) }
        }
        let services = project.services.map { ($0, standard($0.cwd)) }

        var items: [DiskItem] = []
        var tools: [String] = []
        var toolBytes: UInt64 = 0
        for entry in found {
            let size = allocatedSize(entry.path)
            if entry.category == .tools {
                tools.append(entry.path)
                toolBytes += size
                continue
            }
            let parent = (entry.path as NSString).deletingLastPathComponent
            let folder = relative(parent, to: rootForRelative)
            let owner = services.first { $0.1 == parent }?.0
            var item = DiskItem(
                id: entry.path, name: entry.name, category: entry.category, paths: [entry.path], bytes: size,
                folder: folder, parent: parent, serviceID: owner?.id,
                worktree: worktrees.contains(String(folder.split(separator: "/").first ?? "")),
                install: nil, installSource: nil, detail: nil
            )
            if entry.category == .dependencies {
                if entry.name != "node_modules" { item.detail = pythonVersion(venv: entry.path) }
                if let custom = owner?.install {
                    item.install = custom
                    item.installSource = "config.json"
                } else if let picked = installCommand(dependency: entry.name, folder: parent, serviceCommand: owner?.command) {
                    item.install = picked.command
                    item.installSource = picked.source
                }
            }
            items.append(item)
        }
        if !tools.isEmpty {
            items.append(DiskItem(
                id: "\(project.id)#tools", name: "Tool caches", category: .tools, paths: tools, bytes: toolBytes,
                folder: "", parent: rootForRelative, serviceID: nil, worktree: false,
                install: nil, installSource: nil, detail: tools.count == 1 ? "1 folder" : "\(tools.count) folders"
            ))
        }
        items.sort { $0.bytes > $1.bytes }
        return ProjectDisk(id: project.id, name: project.name, root: rootForRelative, items: items,
                           worktreeCount: worktrees.count, leftovers: leftovers)
    }

    private static func walk(_ dir: String, depth: Int, maxDepth: Int,
                             found: inout [(path: String, name: String, category: DiskCategory)], leftovers: inout [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let siblings = Set(names)
        for name in names {
            let path = dir + "/" + name
            guard isPlainDirectory(path) else { continue }
            if skipNames.contains(name) { continue }
            if name.hasPrefix(leftoverPrefix) {
                leftovers.append(path)
                continue
            }
            if name == "node_modules" {
                // Never walk into node_modules; it only counts next to a package.json.
                if siblings.contains("package.json") { found.append((path, name, .dependencies)) }
                continue
            }
            if (name == ".venv" || name == "venv"), FileManager.default.fileExists(atPath: path + "/pyvenv.cfg") {
                found.append((path, name, .dependencies))
                continue
            }
            if let markers = buildMarkers[name], markers.contains(where: siblings.contains) {
                found.append((path, name, .build))
                continue
            }
            if toolNames.contains(name) {
                found.append((path, name, .tools))
                continue
            }
            if depth < maxDepth { walk(path, depth: depth + 1, maxDepth: maxDepth, found: &found, leftovers: &leftovers) }
        }
    }

    /// Space the folder takes on disk (allocated blocks, hard links counted once), like `du -sk`.
    public static func allocatedSize(_ path: String) -> UInt64 {
        var total: UInt64 = 0
        var seen = Set<UInt64>()
        guard let cpath = strdup(path) else { return 0 }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            guard info != FTS_DP, info != FTS_DNR, info != FTS_ERR, info != FTS_NS, let st = entry.pointee.fts_statp?.pointee else { continue }
            if info != FTS_D, st.st_nlink > 1, !seen.insert(UInt64(st.st_ino)).inserted { continue }
            total += UInt64(st.st_blocks) * 512
        }
        return total
    }

    /// The command that reinstalls `node_modules` or a virtualenv in `folder`, from its lockfile.
    /// `serviceCommand` breaks ties when a folder has more than one lockfile.
    public static func installCommand(dependency name: String, folder: String, serviceCommand: String?) -> (command: String, source: String)? {
        let fm = FileManager.default
        func has(_ file: String) -> Bool { fm.fileExists(atPath: folder + "/" + file) }
        if name == "node_modules" {
            let options: [(tool: String, lock: String, command: String)] = [
                ("pnpm", "pnpm-lock.yaml", "pnpm install --frozen-lockfile"),
                ("yarn", "yarn.lock", "yarn install --frozen-lockfile"),
                ("bun", "bun.lock", "bun install --frozen-lockfile"),
                ("bun", "bun.lockb", "bun install --frozen-lockfile"),
                ("npm", "package-lock.json", "npm ci"),
            ].filter { has($0.lock) }
            var tool = serviceCommand?.split(separator: " ").first.map(String.init) ?? ""
            if tool == "npx" { tool = "npm" }
            if let match = options.first(where: { $0.tool == tool }) ?? options.first { return (match.command, match.lock) }
            return has("package.json") ? ("npm install", "package.json") : nil
        }
        let python = pythonExecutable(venv: folder + "/" + name).map(shellQuote) ?? "python3"
        if name == ".venv", has("uv.lock") { return ("uv sync", "uv.lock") }
        if has("requirements.txt") {
            return ("\(python) -m venv \(name) && \(name)/bin/pip install -r requirements.txt", "requirements.txt")
        }
        if has("pyproject.toml") {
            return ("\(python) -m venv \(name) && \(name)/bin/pip install -e .", "pyproject.toml")
        }
        return nil
    }

    /// "Python 3.12", from the venv's pyvenv.cfg.
    static func pythonVersion(venv: String) -> String? {
        guard let cfg = pyvenvConfig(venv), let version = cfg["version"] ?? cfg["version_info"] else { return nil }
        let parts = version.split(separator: ".").prefix(2)
        return parts.count == 2 ? "Python \(parts.joined(separator: "."))" : nil
    }

    /// The interpreter the venv was made with, so the new one uses the same Python.
    static func pythonExecutable(venv: String) -> String? {
        guard let home = pyvenvConfig(venv)?["home"] else { return nil }
        for name in ["python3", "python"] where FileManager.default.isExecutableFile(atPath: home + "/" + name) {
            return home + "/" + name
        }
        return nil
    }

    static func pyvenvConfig(_ venv: String) -> [String: String]? {
        guard let text = try? String(contentsOfFile: venv + "/pyvenv.cfg", encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    static func isWorktree(_ path: String) -> Bool {
        var st = stat()
        return lstat(path + "/.git", &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    static func isPlainDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func standard(_ path: String) -> String {
        URL(fileURLWithPath: Paths.expand(path)).standardizedFileURL.path
    }

    static func relative(_ path: String, to root: String) -> String {
        if path == root { return "" }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : Paths.abbreviate(path)
    }

    static func commonParent(_ paths: [String]) -> String {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return "/" }
        for p in paths.dropFirst() {
            while !(p == common || p.hasPrefix(common + "/")), common != "/" {
                common = (common as NSString).deletingLastPathComponent
            }
        }
        return common
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-@+".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum DiskCleaner {
    /// Folder names Runbar is allowed to delete. Anything else is refused.
    public static let deletableNames: Set<String> = Set(DiskScanner.buildMarkers.keys)
        .union(DiskScanner.toolNames)
        .union(["node_modules", ".venv", "venv"])

    public struct Refused: Error, CustomStringConvertible {
        public var description: String
    }

    /// Deletes `path` permanently, after checking that it is a real folder (not a symlink) with a
    /// known name, strictly inside `root`. The folder is first renamed next to itself, so it
    /// disappears at once and a delete cut short is found and finished by the next scan.
    public static func remove(_ path: String, within root: String) throws {
        let target = DiskScanner.standard(path)
        let base = DiskScanner.standard(root)
        let name = (target as NSString).lastPathComponent
        guard base != "/", target.hasPrefix(base + "/") else {
            throw Refused(description: "\(Paths.abbreviate(target)) is outside \(Paths.abbreviate(base))")
        }
        guard deletableNames.contains(name) || name.hasPrefix(DiskScanner.leftoverPrefix) else {
            throw Refused(description: "Runbar doesn't delete folders named \(name)")
        }
        guard DiskScanner.isPlainDirectory(target) else {
            if FileManager.default.fileExists(atPath: target) {
                throw Refused(description: "\(Paths.abbreviate(target)) is not a plain folder")
            }
            return
        }
        var doomed = target
        if !name.hasPrefix(DiskScanner.leftoverPrefix) {
            let parent = (target as NSString).deletingLastPathComponent
            let moved = parent + "/" + DiskScanner.leftoverPrefix + name + "-" + UUID().uuidString.prefix(8)
            if rename(target, moved) == 0 { doomed = moved }
        }
        do {
            try FileManager.default.removeItem(atPath: doomed)
        } catch {
            throw Refused(description: "couldn't delete \(Paths.abbreviate(target)): \(error.localizedDescription)")
        }
    }
}
