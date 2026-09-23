import Foundation

/// `OmitX --license <command>` — exercises the licensing flow from a terminal, no UI needed.
///
/// For end-to-end checks against a locally running backend:
///
///     OMITX_API=http://127.0.0.1:8891 swift run OmitX --license activate 865M8-…
///
/// Output is for developers, so it is English and not localized.
@MainActor
enum LicenseCLI {
    static func run(_ args: [String]) {
        Pro.installIfAvailable()
        guard Pro.license != nil else {
            print("This build does not include Pro.")
            exit(2)
        }
        // Run the event loop instead of blocking the main thread: the licensing calls are all on the
        // MainActor, so blocking the main thread while waiting for them would deadlock.
        Task {
            exit(await execute(args))
        }
        RunLoop.main.run()
    }

    private static func execute(_ args: [String]) async -> Int32 {
        guard let gate = Pro.license else { return 2 }
        let command = args.first ?? "status"
        let argument = args.count > 1 ? args[1] : ""
        do {
            switch command {
            case "status":
                await gate.refresh()
            case "activate":
                try await gate.activate(code: argument)
            case "trial":
                try await gate.startTrial()
            case "transfer":
                print("OTP sent to \(try await gate.requestTransfer(code: argument))")
            case "confirm":
                try await gate.confirmTransfer(code: argument, otp: args.count > 2 ? args[2] : "")
            case "deactivate":
                try await gate.deactivate()
            default:
                print("Commands: status | activate <code> | trial | transfer <code> | confirm <code> <otp> | deactivate")
                return 2
            }
        } catch {
            print("✗ \(error.localizedDescription)")
            report()
            return 1
        }
        report()
        return 0
    }

    private static func report() {
        print("state   : \(describe(Pro.state))")
        if let info = Pro.info {
            print("code    : \(info.code) (\(info.plan))")
            print("expires : \(info.expires.formatted(.iso8601))")
            print("machine : \(info.machineHint)…")
        }
    }

    private static func describe(_ state: LicenseState) -> String {
        switch state {
        case .none: "not activated"
        case .trial(let days): "trial, \(days) days left"
        case .active: "active"
        case .grace(let days): "grace period, \(days) days left"
        case .expired: "expired"
        case .revoked: "revoked"
        }
    }
}
