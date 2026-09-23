import Foundation

/// Scans work folders for build artifacts in each project
/// (node_modules, build/, .dart_tool, Pods, target/, .build, .venv...).
extension ProjectModule {
    static let idValue = "projects"
}

struct ProjectModule: CleanModule {
    let id = "projects"
    let title = L("Project")
    let icon = "folder.fill.badge.gearshape"
    let summary = L("node_modules, build/, .dart_tool, .gradle, Pods, target/, .build, .next, .venv... trong các project")

    var roots: [URL]
    var maxDepth: Int
    var staleDays: Int

    struct Rule: Sendable {
        let name: String
        let markers: [String]        // files next to the artifact; "*.ext" = any .ext file; empty = none required
        let kind: String
        var safety: Safety = .safe
        var note: String? = nil
        var requiresInside: String? = nil  // the artifact must contain this file (e.g. pyvenv.cfg)
    }

    static let gradleMarkers = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"]
    static let jsMarkers = ["package.json"]

    static let rules: [Rule] = [
        Rule(name: "node_modules", markers: jsMarkers, kind: "Node", note: L("npm/yarn/pnpm install để cài lại")),
        Rule(name: "build", markers: ["pubspec.yaml"], kind: "Flutter"),
        Rule(name: ".dart_tool", markers: ["pubspec.yaml"], kind: "Dart"),
        Rule(name: "build", markers: gradleMarkers, kind: "Gradle"),
        Rule(name: ".gradle", markers: gradleMarkers, kind: "Gradle"),
        Rule(name: ".cxx", markers: gradleMarkers, kind: "Android NDK"),
        Rule(name: ".externalNativeBuild", markers: gradleMarkers, kind: "Android NDK"),
        Rule(name: ".kotlin", markers: gradleMarkers, kind: "Kotlin"),
        Rule(name: "Pods", markers: ["Podfile"], kind: "CocoaPods", note: L("pod install để cài lại")),
        Rule(name: ".build", markers: ["Package.swift"], kind: "SwiftPM"),
        Rule(name: "DerivedData", markers: ["*.xcodeproj", "*.xcworkspace"], kind: "Xcode"),
        Rule(name: "target", markers: ["Cargo.toml"], kind: "Rust"),
        Rule(name: "target", markers: ["pom.xml"], kind: "Maven"),
        Rule(name: ".next", markers: jsMarkers, kind: "Next.js"),
        Rule(name: ".nuxt", markers: jsMarkers, kind: "Nuxt"),
        Rule(name: ".output", markers: ["nuxt.config.ts", "nuxt.config.js"], kind: "Nuxt"),
        Rule(name: ".svelte-kit", markers: jsMarkers, kind: "SvelteKit"),
        Rule(name: ".turbo", markers: jsMarkers, kind: "Turborepo"),
        Rule(name: ".parcel-cache", markers: jsMarkers, kind: "Parcel"),
        Rule(name: ".angular", markers: jsMarkers, kind: "Angular"),
        Rule(name: ".expo", markers: jsMarkers, kind: "Expo"),
        Rule(name: ".vercel", markers: jsMarkers, kind: "Vercel", safety: .caution, note: L("Chứa link project Vercel")),
        Rule(name: ".venv", markers: [], kind: "Python venv", safety: .caution, note: L("Phải tạo lại venv + cài lại package"),
             requiresInside: "pyvenv.cfg"),
        Rule(name: "venv", markers: [], kind: "Python venv", safety: .caution, note: L("Phải tạo lại venv + cài lại package"),
             requiresInside: "pyvenv.cfg"),
        Rule(name: ".pytest_cache", markers: [], kind: "pytest"),
        Rule(name: ".mypy_cache", markers: [], kind: "mypy"),
        Rule(name: ".ruff_cache", markers: [], kind: "Ruff"),
        Rule(name: ".tox", markers: [], kind: "tox"),
        Rule(name: ".zig-cache", markers: ["build.zig"], kind: "Zig"),
        Rule(name: "zig-out", markers: ["build.zig"], kind: "Zig"),
        Rule(name: "_build", markers: ["mix.exs"], kind: "Elixir"),
        Rule(name: ".stack-work", markers: ["stack.yaml"], kind: "Haskell"),
        Rule(name: "elm-stuff", markers: ["elm.json"], kind: "Elm"),
        Rule(name: "bin", markers: ["*.csproj", "*.fsproj"], kind: ".NET"),
        Rule(name: "obj", markers: ["*.csproj", "*.fsproj"], kind: ".NET"),
        Rule(name: ".terraform", markers: ["*.tf"], kind: "Terraform", note: L("terraform init để tải lại provider")),
        Rule(name: "cmake-build-debug", markers: ["CMakeLists.txt"], kind: "CMake"),
        Rule(name: "cmake-build-release", markers: ["CMakeLists.txt"], kind: "CMake"),
    ]

    static let ruleNames = Set(rules.map(\.name))

    /// Folders never descended into while scanning.
    static let skipNames: Set<String> = [".git", ".hg", ".svn", "node_modules", "Library", ".Trash", "Pictures", "Music",
                                         "Movies", "Applications", ".cache", ".npm", ".gradle", ".cargo", ".rustup",
                                         ".pub-cache", ".m2", ".nvm", ".android", ".cocoapods", ".vscode", ".cursor",
                                         "Photos Library.photoslibrary", "go", ".docker", ".orbstack", ".colima"]

    func scan() async -> ScanResult {
        let found = await Task.detached(priority: .userInitiated) { [roots, maxDepth] in
            var out: [Found] = []
            for root in roots { Self.walk(root, depth: 0, maxDepth: maxDepth, projectRoot: nil, into: &out) }
            return out
        }.value

        let staleCutoff = Date().addingTimeInterval(-Double(staleDays) * 86_400)
        let items: [CleanItem] = await concurrentMap(found, limit: 8) { f in
            let size = DiskUsage.size(of: f.url)
            let project = f.projectRoot
            let activity = Self.lastActivity(project)
            let stale = (activity ?? .distantPast) < staleCutoff
            let rel = f.url.path.replacingOccurrences(of: project.path + "/", with: "")
            return CleanItem(
                id: "path:" + f.url.standardizedFileURL.path,
                title: "\(rel)  ·  \(f.rule.kind)",
                detail: f.url.path.abbreviatingHome,
                group: project.path.abbreviatingHome,
                size: size, safety: f.rule.safety, note: f.rule.note,
                action: .delete(f.url),
                selectedByDefault: stale && f.rule.safety == .safe,
                lastModified: activity)
        }
        let nonEmpty = items.filter { $0.size >= 64 * 1024 }
        var notes = [L("Chọn sẵn artifact của project không đụng tới hơn \(staleDays) ngày (theo git / file marker).")]
        if roots.isEmpty { notes = [L("Chưa chọn thư mục để quét — vào Cài đặt để thêm.")] }
        return ScanResult(items: nonEmpty, notes: notes)
    }

    struct Found: Sendable {
        let url: URL
        let rule: Rule
        let projectRoot: URL
    }

    static func walk(_ dir: URL, depth: Int, maxDepth: Int, projectRoot: URL?, into out: inout [Found]) {
        guard depth <= maxDepth else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }

        let names = Set(entries.map(\.lastPathComponent))
        let exts = Set(entries.map(\.pathExtension).filter { !$0.isEmpty })
        let project = names.contains(".git") ? dir : projectRoot

        func markerPresent(_ markers: [String]) -> Bool {
            markers.isEmpty || markers.contains { m in
                m.hasPrefix("*.") ? exts.contains(String(m.dropFirst(2))) : names.contains(m)
            }
        }

        for entry in entries {
            guard let v = try? entry.resourceValues(forKeys: Set(keys)),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            let name = entry.lastPathComponent

            if ruleNames.contains(name),
               let rule = rules.first(where: { $0.name == name && markerPresent($0.markers)
                   && ($0.requiresInside.map { entry.appendingPathComponent($0).exists } ?? true) }) {
                out.append(Found(url: entry, rule: rule, projectRoot: project ?? dir))
                continue // do not descend into the artifact
            }
            if skipNames.contains(name) || v.isPackage == true { continue }
            if name.hasPrefix(".") { continue }
            walk(entry, depth: depth + 1, maxDepth: maxDepth, projectRoot: project, into: &out)
        }
    }

    /// When the project was last worked on: the mtime of .git/index, or of the newest marker file.
    static func lastActivity(_ project: URL) -> Date? {
        let candidates = [".git/index", ".git/HEAD", "package.json", "pubspec.yaml", "build.gradle", "Podfile",
                          "Cargo.toml", "Package.swift", "pyproject.toml", "pom.xml"]
        let dates = candidates.compactMap { project.appendingPathComponent($0).modificationDate }
        return dates.max() ?? project.modificationDate
    }
}
