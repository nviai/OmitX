import Foundation

struct PythonModule: CleanModule {
    let id = "python"
    let title = "Python & AI/ML"
    let icon = "brain.head.profile"
    let summary = "pip, uv, poetry, conda pkgs, pyenv, Hugging Face / Ollama / torch models"

    func scan() async -> ScanResult {
        let c = L("Package cache")
        var specs: [PathSpec] = [
            PathSpec(home: "Library/Caches/pip", "pip cache", group: c),
            PathSpec(home: ".cache/pip", "pip cache (XDG)", group: c),
            PathSpec(home: ".cache/uv", "uv cache", group: c, note: L("Tương đương uv cache clean")),
            PathSpec(home: "Library/Caches/uv", "uv cache", group: c),
            PathSpec(home: "Library/Caches/pypoetry/cache", "Poetry cache", group: c),
            PathSpec(home: "Library/Caches/pypoetry/artifacts", "Poetry artifacts", group: c),
            PathSpec(home: "Library/Caches/pypoetry/virtualenvs", "Poetry virtualenvs", group: c, safety: .caution,
                     note: L("Project poetry sẽ phải poetry install lại"), selected: false),
            PathSpec(home: "Library/Caches/pipenv", "pipenv cache", group: c),
            PathSpec(home: ".cache/pre-commit", "pre-commit hooks", group: c),
            PathSpec(home: ".cache/pdm", "PDM cache", group: c),
            PathSpec(home: "Library/Caches/pdm", "PDM cache", group: c),
            PathSpec(home: ".cache/ruff", "Ruff cache", group: c),
            PathSpec(home: ".cache/black", "Black cache", group: c),
            PathSpec(home: ".cache/mypy", "mypy cache", group: c),
            PathSpec(home: "Library/Caches/pypoetry/repository", "Poetry repository cache", group: c),
        ]

        // pyenv / asdf / mise
        for (mgr, dir) in [("pyenv", URL.homePath(".pyenv/versions")),
                           ("asdf", URL.homePath(".asdf/installs/python")),
                           ("mise", URL.homePath(".local/share/mise/installs/python")),
                           ("uv", URL.homePath(".local/share/uv/python"))] {
            specs += ScanKit.children(of: dir, group: L("Phiên bản Python"), safety: .caution,
                                      note: L("virtualenv tạo từ bản này sẽ hỏng"), selected: false,
                                      title: { "Python \($0.lastPathComponent) (\(mgr))" })
        }

        // AI/ML models — often very large
        let ml = L("Model AI/ML")
        let hfHub = URL.homePath(".cache/huggingface/hub")
        specs += ScanKit.children(of: hfHub, group: ml, safety: .caution, note: L("Model sẽ được tải lại khi dùng"),
                                  selected: false, filter: { $0.lastPathComponent.hasPrefix("models--") || $0.lastPathComponent.hasPrefix("datasets--") },
                                  title: { url in
            let n = url.lastPathComponent
            let kind = n.hasPrefix("datasets--") ? "dataset" : "model"
            let name = n.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "datasets--", with: "")
                .replacingOccurrences(of: "--", with: "/")
            return "HF \(kind): \(name)"
        })
        specs += [
            PathSpec(home: ".cache/huggingface/datasets", "Hugging Face datasets cache", group: ml, safety: .caution, selected: false),
            PathSpec(home: ".cache/huggingface/xet", "Hugging Face xet cache", group: ml),
            PathSpec(home: ".cache/torch", "PyTorch hub cache", group: ml, safety: .caution, selected: false),
            PathSpec(home: ".cache/whisper", "Whisper models", group: ml, safety: .caution, selected: false),
            PathSpec(home: ".keras/datasets", "Keras datasets", group: ml, safety: .caution, selected: false),
            PathSpec(home: ".ollama/models", L("Ollama models (toàn bộ)"), group: ml, safety: .caution,
                     note: L("Nên dùng 'ollama rm <model>' để xoá từng model"), selected: false),
            PathSpec(home: ".lmstudio/models", "LM Studio models", group: ml, safety: .caution, selected: false),
            PathSpec(home: ".cache/lm-studio/models", L("LM Studio models (cũ)"), group: ml, safety: .caution, selected: false),
        ]

        var items = await ScanKit.measure(specs)

        // Conda: use `conda clean --all` instead of deleting by hand
        for base in Self.condaBases() {
            let conda = base.appendingPathComponent("bin/conda")
            guard FileManager.default.isExecutableFile(atPath: conda.path) else { continue }
            let pkgs = base.appendingPathComponent("pkgs")
            let size = await Task.detached { DiskUsage.size(of: pkgs) }.value
            if size > 0 {
                items.append(ScanKit.commandItem(
                    id: "cmd:conda-clean:\(base.path)", title: "conda clean --all (\(base.lastPathComponent))",
                    group: "Conda",
                    command: ShellCommand(executable: conda.path, arguments: ["clean", "--all", "--yes"]),
                    size: size, note: L("Xoá tarball + package không còn env nào dùng. Dung lượng thực tế có thể nhỏ hơn (package đang link vào env được giữ)."),
                    detail: pkgs.path.abbreviatingHome))
            }
            let envSpecs = ScanKit.children(of: base.appendingPathComponent("envs"), group: "Conda envs", safety: .danger,
                                            note: L("Xoá cả môi trường conda + package đã cài"), selected: false,
                                            title: { "env: \($0.lastPathComponent)" })
            items += await ScanKit.measure(envSpecs)
        }
        return ScanResult(items: items, notes: [L("Thư mục .venv / __pycache__ trong từng project nằm ở mục \"Project\".")])
    }

    static func condaBases() -> [URL] {
        let h = URL.home
        return [URL(fileURLWithPath: "/opt/miniconda3"), URL(fileURLWithPath: "/opt/anaconda3"),
                h.appendingPathComponent("miniconda3"), h.appendingPathComponent("anaconda3"),
                h.appendingPathComponent("miniforge3"), h.appendingPathComponent("mambaforge"),
                URL(fileURLWithPath: "/opt/homebrew/Caskroom/miniconda/base"),
                URL(fileURLWithPath: "/opt/homebrew/Caskroom/miniforge/base")]
            .filter(\.isDirectory)
    }
}
