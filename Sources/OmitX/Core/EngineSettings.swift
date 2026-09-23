import Foundation

/// Settings that both the app and the background agent need to read.
///
/// Keeps the UserDefaults keys used so far, so existing users
/// do not lose their settings when updating.
struct EngineSettings: Codable, Hashable, Sendable {
    var deleteMode: DeleteMode = .permanent
    var projectRoots: [URL] = []
    var projectMaxDepth: Int = 7
    var staleDays: Int = 30

    enum Key {
        static let deleteMode = "deleteMode"
        static let projectRoots = "projectRoots"
        static let projectMaxDepth = "projectMaxDepth"
        static let staleDays = "staleDays"
    }

    static func load(from d: UserDefaults = .standard) -> EngineSettings {
        EngineSettings(
            deleteMode: DeleteMode(rawValue: d.string(forKey: Key.deleteMode) ?? "") ?? .permanent,
            projectRoots: (d.stringArray(forKey: Key.projectRoots) ?? defaultProjectRoots().map(\.path))
                .map { URL(fileURLWithPath: $0, isDirectory: true) },
            projectMaxDepth: d.object(forKey: Key.projectMaxDepth) as? Int ?? 7,
            staleDays: d.object(forKey: Key.staleDays) as? Int ?? 30)
    }

    func save(to d: UserDefaults = .standard) {
        d.set(deleteMode.rawValue, forKey: Key.deleteMode)
        d.set(projectRoots.map(\.path), forKey: Key.projectRoots)
        d.set(projectMaxDepth, forKey: Key.projectMaxDepth)
        d.set(staleDays, forKey: Key.staleDays)
    }

    /// Common folders that contain projects.
    static func defaultProjectRoots() -> [URL] {
        let found = ["Workspaces", "Workspace", "workspace", "Projects", "projects", "Developer", "Code", "code", "dev",
                     "src", "Sites", "repos", "git", "GitHub", "Documents/GitHub", "Documents/Projects"]
            .map { URL.homePath($0) }.filter(\.isDirectory)
        return found.isEmpty ? [URL.home] : found
    }
}
