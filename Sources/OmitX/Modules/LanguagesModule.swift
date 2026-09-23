import Foundation

struct LanguagesModule: CleanModule {
    let id = "languages"
    let title = L("Rust, Go, Java & khác")
    let icon = "chevron.left.forwardslash.chevron.right"
    let summary = "Cargo, rustup, Go build/mod cache, Maven, SDKMAN, Ruby gems, NuGet, Composer, ccache, Bazel"

    func scan() async -> ScanResult {
        var specs: [PathSpec] = []

        // Rust
        let rust = "Rust"
        specs += [
            PathSpec(home: ".cargo/registry/cache", "Cargo registry cache (.crate)", group: rust),
            PathSpec(home: ".cargo/registry/src", "Cargo registry src", group: rust),
            PathSpec(home: ".cargo/registry/index", "Cargo registry index", group: rust),
            PathSpec(home: ".cargo/git/checkouts", "Cargo git checkouts", group: rust),
            PathSpec(home: ".cargo/git/db", "Cargo git db", group: rust),
            PathSpec(home: ".rustup/downloads", "rustup downloads", group: rust),
            PathSpec(home: ".rustup/tmp", "rustup tmp", group: rust),
            PathSpec(home: "Library/Caches/sccache", "sccache", group: rust),
            PathSpec(home: "Library/Caches/Mozilla.sccache", "sccache", group: rust),
        ]
        specs += ScanKit.children(of: .homePath(".rustup/toolchains"), group: "Rust toolchains", safety: .caution,
                                  note: L("rustup toolchain install để cài lại"), selected: false,
                                  title: { "Toolchain \($0.lastPathComponent)" })

        // Go
        let go = "Go"
        let goPath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GOPATH"] ?? URL.homePath("go").path)
        specs += [
            PathSpec(home: "Library/Caches/go-build", "Go build cache", group: go, note: L("Tương đương go clean -cache")),
            PathSpec(goPath.appendingPathComponent("pkg/mod"), "Go module cache", group: go,
                     note: L("Tương đương go clean -modcache. Module sẽ tải lại khi build.")),
            PathSpec(home: "Library/Caches/gopls", "gopls cache", group: go),
            PathSpec(home: "Library/Caches/golangci-lint", "golangci-lint cache", group: go),
            PathSpec(home: "Library/Caches/staticcheck", "staticcheck cache", group: go),
        ]

        // JVM
        let jvm = "Java / JVM"
        specs += [
            PathSpec(home: ".m2/repository", "Maven local repository", group: jvm, note: L("mvn sẽ tải lại dependency")),
            PathSpec(home: ".m2/wrapper/dists", "Maven wrapper dists", group: jvm),
            PathSpec(home: ".sdkman/archives", "SDKMAN archives", group: jvm),
            PathSpec(home: ".sdkman/tmp", "SDKMAN tmp", group: jvm),
            PathSpec(home: "Library/Caches/Coursier", "Coursier (Scala) cache", group: jvm),
            PathSpec(home: ".ivy2/cache", "Ivy cache", group: jvm),
            PathSpec(home: ".sbt/boot", "sbt boot", group: jvm),
            PathSpec(home: "Library/Caches/kotlin-language-server", "Kotlin LS cache", group: jvm),
        ]
        for cand in URL.homePath(".sdkman/candidates").children(includeHidden: false) {
            specs += ScanKit.children(of: cand, group: "SDKMAN candidates", safety: .caution, selected: false,
                                      filter: { $0.lastPathComponent != "current" },
                                      title: { "\(cand.lastPathComponent) \($0.lastPathComponent)" })
        }

        // Ruby
        let ruby = "Ruby"
        specs += [
            PathSpec(home: ".bundle/cache", "Bundler cache", group: ruby),
            PathSpec(home: ".gem/specs", "RubyGems specs cache", group: ruby),
            PathSpec(home: "Library/Caches/rubygems", "RubyGems cache", group: ruby),
        ]
        for (mgr, dir) in [("rbenv", URL.homePath(".rbenv/versions")), ("rvm", URL.homePath(".rvm/rubies")),
                           ("asdf", URL.homePath(".asdf/installs/ruby")), ("mise", URL.homePath(".local/share/mise/installs/ruby"))] {
            specs += ScanKit.children(of: dir, group: ruby, safety: .caution, note: L("Gem cài trong bản này sẽ mất"), selected: false,
                                      title: { "Ruby \($0.lastPathComponent) (\(mgr))" })
        }

        // .NET, PHP, C/C++, others
        let other = L("Khác")
        specs += [
            PathSpec(home: ".nuget/packages", "NuGet packages", group: other),
            PathSpec(home: ".local/share/NuGet/v3-cache", "NuGet http cache", group: other),
            PathSpec(home: ".local/share/NuGet/http-cache", "NuGet http cache", group: other),
            PathSpec(home: "Library/Caches/composer", "Composer cache", group: other),
            PathSpec(home: ".composer/cache", L("Composer cache (cũ)"), group: other),
            PathSpec(home: "Library/Caches/ccache", "ccache", group: other),
            PathSpec(home: ".ccache", L("ccache (cũ)"), group: other),
            PathSpec(home: ".cache/bazel", "Bazel cache", group: other, safety: .caution),
            PathSpec(home: "Library/Caches/bazelisk", "Bazelisk", group: other),
            PathSpec(URL(fileURLWithPath: "/private/var/tmp/_bazel_\(NSUserName())"), "Bazel output base", group: other, safety: .caution),
            PathSpec(home: ".stack/programs", "Haskell Stack GHC", group: other, safety: .caution, selected: false),
            PathSpec(home: ".cabal/packages", "Cabal packages", group: other),
            PathSpec(home: ".hex/packages", "Hex (Elixir) packages", group: other),
            PathSpec(home: ".cache/rebar3", "rebar3 cache", group: other),
            PathSpec(home: ".terraform.d/plugin-cache", "Terraform plugin cache", group: other),
            PathSpec(home: "Library/Caches/helm", "Helm cache", group: other),
            PathSpec(home: ".cache/zig", "Zig cache", group: other),
        ]
        return ScanResult(items: await ScanKit.measure(specs))
    }
}
