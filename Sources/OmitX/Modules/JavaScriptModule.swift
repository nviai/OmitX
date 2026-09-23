import Foundation

struct JavaScriptModule: CleanModule {
    let id = "javascript"
    let title = "Node.js / JavaScript"
    let icon = "curlybraces"
    let summary = L("npm, yarn, pnpm, bun, deno, node-gyp, Playwright/Cypress browsers, các bản Node cũ")

    func scan() async -> ScanResult {
        let pm = L("Package manager cache")
        var specs: [PathSpec] = [
            PathSpec(home: ".npm/_cacache", "npm cache", group: pm, note: L("Tương đương npm cache clean --force")),
            PathSpec(home: ".npm/_npx", "npx cache", group: pm),
            PathSpec(home: ".npm/_logs", "npm logs", group: pm),
            PathSpec(home: "Library/Caches/Yarn", "Yarn v1 cache", group: pm),
            PathSpec(home: ".yarn/berry/cache", "Yarn Berry cache", group: pm),
            PathSpec(home: ".yarn/cache", "Yarn cache (~/.yarn/cache)", group: pm),
            PathSpec(home: "Library/Caches/pnpm", "pnpm metadata cache", group: pm),
            PathSpec(home: "Library/pnpm/store", L("pnpm store (toàn bộ)"), group: pm, safety: .caution,
                     note: L("node_modules của project pnpm hard-link vào đây. Xoá xong cần pnpm install lại. Ưu tiên 'pnpm store prune'."),
                     selected: false),
            PathSpec(home: ".local/share/pnpm/store", "pnpm store (XDG)", group: pm, safety: .caution, selected: false),
            PathSpec(home: ".bun/install/cache", "bun cache", group: pm),
            PathSpec(home: "Library/Caches/deno", "Deno cache", group: pm),
            PathSpec(home: ".cache/node/corepack", "Corepack cache", group: pm),
        ]

        let build = L("Build tools")
        specs += [
            PathSpec(home: "Library/Caches/node-gyp", "node-gyp headers", group: build),
            PathSpec(home: ".node-gyp", L("node-gyp (cũ)"), group: build),
            PathSpec(home: "Library/Caches/typescript", "TypeScript cache", group: build),
            PathSpec(home: "Library/Caches/electron", "Electron binaries", group: build),
            PathSpec(home: "Library/Caches/electron-builder", "electron-builder cache", group: build),
            PathSpec(home: "Library/Caches/turbo", "Turborepo cache", group: build),
            PathSpec(home: ".cache/prisma", "Prisma engines", group: build),
            PathSpec(home: "Library/Caches/esbuild", "esbuild cache", group: build),
            PathSpec(home: "Library/Caches/next-swc", "Next.js SWC cache", group: build),
            PathSpec(home: ".expo", "Expo cache", group: build, safety: .caution, note: L("Có thể chứa phiên đăng nhập Expo"), selected: false),
        ]

        let browsers = L("Trình duyệt test")
        specs += [
            PathSpec(home: "Library/Caches/ms-playwright", "Playwright browsers", group: browsers, safety: .caution,
                     note: L("npx playwright install để tải lại")),
            PathSpec(home: ".cache/puppeteer", "Puppeteer Chrome", group: browsers, safety: .caution),
            PathSpec(home: "Library/Caches/Cypress", "Cypress binaries", group: browsers, safety: .caution),
            PathSpec(home: ".cache/selenium", "Selenium drivers", group: browsers),
        ]

        // Node versions installed by version managers
        let nodeGroup = L("Phiên bản Node.js")
        let managers: [(String, URL)] = [
            ("nvm", .homePath(".nvm/versions/node")),
            ("fnm", .homePath("Library/Application Support/fnm/node-versions")),
            ("fnm", .homePath(".local/share/fnm/node-versions")),
            ("volta", .homePath(".volta/tools/image/node")),
            ("n", URL(fileURLWithPath: "/usr/local/n/versions/node")),
            ("asdf", .homePath(".asdf/installs/nodejs")),
            ("mise", .homePath(".local/share/mise/installs/node")),
        ]
        for (manager, dir) in managers {
            specs += ScanKit.children(of: dir, group: nodeGroup, safety: .caution,
                                      note: L("Global package cài trong bản này sẽ mất"), selected: false,
                                      title: { "Node \($0.lastPathComponent) (\(manager))" })
        }
        specs.append(PathSpec(home: ".nvm/.cache", "nvm download cache", group: nodeGroup))

        var items = await ScanKit.measure(specs)
        if Shell.has("pnpm"), URL.homePath("Library/pnpm/store").exists {
            items.append(ScanKit.commandItem(
                id: "cmd:pnpm-store-prune", title: "pnpm store prune", group: pm,
                command: ShellCommand(executable: "pnpm", arguments: ["store", "prune"]),
                note: L("Chỉ xoá package không còn project nào tham chiếu (an toàn). Dung lượng chỉ biết sau khi chạy.")))
        }
        return ScanResult(items: items)
    }
}
