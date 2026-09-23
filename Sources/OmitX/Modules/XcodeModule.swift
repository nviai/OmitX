import Foundation

struct XcodeModule: CleanModule {
    let id = "xcode"
    let title = "Xcode & iOS"
    let icon = "hammer.fill"
    let summary = "DerivedData, Archives, DeviceSupport, Xcode cache, SwiftPM, CocoaPods, Carthage"

    func scan() async -> ScanResult {
        let dev = URL.homePath("Library/Developer/Xcode")
        let xcode = ["Xcode"]
        var specs: [PathSpec] = []

        // DerivedData — one item per project
        let derived = dev.appendingPathComponent("DerivedData")
        specs += ScanKit.children(of: derived, group: "DerivedData", note: L("Build lại khi mở project"), blocking: xcode,
                                  title: { url in
            let name = url.lastPathComponent
            // "Runner-abcxyz..." → "Runner"
            if let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) > 20 {
                return String(name[..<dash])
            }
            return name
        })

        // Device Support — keep the newest per platform
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let dir = dev.appendingPathComponent("\(platform) DeviceSupport")
            let children = dir.children(includeHidden: false).sorted { ScanKit.versionLess(versionKey($0), versionKey($1)) }
            let newest = children.last
            for child in children {
                let isNewest = child == newest
                specs.append(PathSpec(child, child.lastPathComponent, group: "\(platform) DeviceSupport",
                                      safety: .safe,
                                      note: isNewest ? L("Bản mới nhất — Xcode sẽ tạo lại khi cắm thiết bị") : L("Tự tạo lại khi cắm thiết bị chạy phiên bản này"),
                                      selected: !isNewest, blocking: xcode))
            }
        }

        // Archives — by date
        specs += ScanKit.children(of: dev.appendingPathComponent("Archives"), group: "Archives", safety: .danger,
                                  note: L("Chứa bản build đã ký + dSYM để symbolicate crash. Chỉ xoá khi chắc chắn."),
                                  title: { "Archives \($0.lastPathComponent)" })

        // Caches & temporary data
        let cacheGroup = L("Cache Xcode")
        specs += [
            PathSpec(dev.appendingPathComponent("Products"), "Xcode Products", group: cacheGroup),
            PathSpec(dev.appendingPathComponent("DocumentationCache"), "Documentation Cache", group: cacheGroup, blocking: xcode),
            PathSpec(dev.appendingPathComponent("DocumentationIndex"), "Documentation Index", group: cacheGroup, blocking: xcode),
            PathSpec(dev.appendingPathComponent("UserData/Previews"), "SwiftUI Previews", group: cacheGroup, blocking: xcode),
            PathSpec(dev.appendingPathComponent("UserData/IB Support"), "Interface Builder Support", group: cacheGroup),
            PathSpec(dev.appendingPathComponent("iOS Device Logs"), "iOS Device Logs", group: cacheGroup),
            PathSpec(home: "Library/Caches/com.apple.dt.Xcode", "Xcode cache", group: cacheGroup, blocking: xcode),
            PathSpec(home: "Library/Caches/com.apple.dt.xcodebuild", "xcodebuild cache", group: cacheGroup),
            PathSpec(home: "Library/Developer/XCPGDevices", "Playground devices", group: cacheGroup),
            PathSpec(home: "Library/Developer/Xcode/XCTestDevices", "XCTest devices", group: cacheGroup),
            PathSpec(home: "Library/Logs/DiagnosticReports/Xcode", "Xcode crash logs", group: cacheGroup),
        ]

        // Dependency managers
        let depGroup = "SwiftPM / CocoaPods / Carthage"
        specs += [
            PathSpec(home: "Library/Caches/org.swift.swiftpm", "SwiftPM cache", group: depGroup, note: L("Package sẽ được tải lại")),
            PathSpec(home: "Library/Caches/CocoaPods", "CocoaPods cache", group: depGroup, note: L("pod install sẽ tải lại")),
            PathSpec(home: ".cocoapods/repos", "CocoaPods spec repos", group: depGroup, safety: .caution,
                     note: L("Dùng CDN (mặc định từ 1.8) thì không cần. Nếu dùng spec repo riêng phải `pod repo add` lại.")),
            PathSpec(home: "Library/Caches/org.carthage.CarthageKit", "Carthage cache", group: depGroup),
            PathSpec(home: "Library/Caches/com.mono.xamarin", "Xamarin cache", group: depGroup),
            PathSpec(home: "Library/Caches/fastlane", "fastlane cache", group: depGroup),
        ]

        var notes: [String] = []
        if Shell.isRunning("Xcode.app/Contents/MacOS/Xcode") {
            notes.append(L("Xcode đang mở — nên tắt Xcode trước khi xoá DerivedData / cache."))
        }
        return ScanResult(items: await ScanKit.measure(specs), notes: notes)
    }

    /// "iPhone14,5 18.6.2 (22G100)" → "18.6.2" for version comparison.
    private func versionKey(_ url: URL) -> String {
        let name = url.lastPathComponent
        let tokens = name.split(separator: " ")
        return tokens.first(where: { $0.first?.isNumber == true && $0.contains(".") }).map(String.init) ?? name
    }
}
