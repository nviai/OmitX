import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
    var combined: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum ShellError: LocalizedError {
    case notFound(String)
    case failed(String, ShellResult)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notFound(let cmd): L("Không tìm thấy lệnh '\(cmd)' trong PATH")
        case .failed(let cmd, let r):
            L("'\(cmd)' lỗi (exit \(r.status)): \(r.combined.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))")
        case .cancelled: L("Người dùng huỷ")
        }
    }
}

enum Shell {
    /// PATH taken from the user's login + interactive shell (so brew, flutter, cargo, nvm… are found).
    static let userPATH: String = resolveUserPATH()

    private static func resolveUserPATH() -> String {
        let fallback = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(NSHomeDirectory())/.cargo/bin", "\(NSHomeDirectory())/go/bin",
            "\(NSHomeDirectory())/.pub-cache/bin", "\(NSHomeDirectory())/development/flutter/bin",
            "\(NSHomeDirectory())/.bun/bin", "\(NSHomeDirectory())/.volta/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__DEVCLEANER_PATH__"
        let r = try? runRaw(shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""],
                            env: ["HOME": NSHomeDirectory(), "TERM": "dumb"], timeout: 8)
        var parts: [String] = []
        if let out = r?.stdout, let a = out.range(of: marker),
           let b = out.range(of: marker, range: a.upperBound..<out.endIndex) {
            parts = out[a.upperBound..<b.lowerBound].split(separator: ":").map(String.init)
        }
        for p in fallback where !parts.contains(p) { parts.append(p) }
        return parts.joined(separator: ":")
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPATH
        env["HOME"] = NSHomeDirectory()
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    /// Finds a command's absolute path in the user's PATH.
    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in userPATH.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func has(_ name: String) -> Bool { which(name) != nil }

    /// Runs a command (synchronous — call from a background thread).
    @discardableResult
    static func run(_ name: String, _ args: [String], timeout: TimeInterval = 600) throws -> ShellResult {
        guard let exe = which(name) else { throw ShellError.notFound(name) }
        return try runRaw(exe, args, env: environment, timeout: timeout)
    }

    static func runAsync(_ name: String, _ args: [String], timeout: TimeInterval = 600) async throws -> ShellResult {
        try await Task.detached(priority: .userInitiated) { try run(name, args, timeout: timeout) }.value
    }

    static func runRaw(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Read both pipes concurrently to avoid a deadlock on large output.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        group.wait()
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Runs a shell command with admin rights (macOS shows a password dialog).
    static func runAdmin(_ script: String) async throws -> String {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        return try await MainActor.run {
            var err: NSDictionary?
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&err) else {
                if let code = err?[NSAppleScript.errorNumber] as? Int, code == -128 { throw ShellError.cancelled }
                let msg = err?[NSAppleScript.errorMessage] as? String ?? L("Lỗi không rõ")
                throw ShellError.failed(script, ShellResult(status: 1, stdout: "", stderr: msg))
            }
            return result.stringValue ?? ""
        }
    }

    static func quote(_ s: String) -> String {
        if s.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Running processes whose name contains `needle` (pgrep -f).
    static func isRunning(_ needle: String) -> Bool {
        (try? runRaw("/usr/bin/pgrep", ["-f", needle], env: environment, timeout: 5))?.ok ?? false
    }
}
