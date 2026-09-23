import Foundation

struct DockerModule: CleanModule {
    let id = "docker"
    let title = "Docker & Container"
    let icon = "shippingbox.fill"
    let summary = L("Image/container/volume không dùng, build cache (Docker, OrbStack, Colima, Podman), Minikube")

    func scan() async -> ScanResult {
        var items: [CleanItem] = []
        var notes: [String] = []

        if Shell.has("docker") {
            let r = try? await Shell.runAsync("docker", ["system", "df", "--format", "{{json .}}"], timeout: 30)
            if let r, r.ok {
                items += parseDockerDF(r.stdout, tool: "docker")
                if items.isEmpty { notes.append(L("Docker không có gì để dọn.")) }
            } else {
                notes.append(L("Docker daemon chưa chạy (Docker Desktop / OrbStack / Colima). Mở lên rồi quét lại."))
            }
        } else {
            notes.append(L("Chưa cài Docker CLI."))
        }

        if Shell.has("podman") {
            if let r = try? await Shell.runAsync("podman", ["system", "df", "--format", "{{json .}}"], timeout: 30), r.ok {
                items += parseDockerDF(r.stdout, tool: "podman")
            }
        }

        let vm = L("Máy ảo & công cụ khác")
        items += await ScanKit.measure([
            PathSpec(home: ".minikube/cache", "Minikube cache (image/ISO)", group: vm),
            PathSpec(home: ".minikube/machines", "Minikube machines", group: vm, safety: .danger,
                     note: L("Xoá cluster minikube — nên dùng 'minikube delete'"), selected: false),
            PathSpec(home: ".colima/_lima/_disks", "Colima disks", group: vm, safety: .danger,
                     note: L("Mất toàn bộ image/container trong Colima. Nên dùng 'colima delete'."), selected: false),
            PathSpec(home: ".lima/_cache", "Lima download cache", group: vm),
            PathSpec(home: "Library/Caches/lima", "Lima cache", group: vm),
            PathSpec(home: ".kube/cache", "kubectl cache", group: vm),
            PathSpec(home: ".vagrant.d/boxes", "Vagrant boxes", group: vm, safety: .caution, selected: false),
            PathSpec(home: "Library/Caches/com.docker.docker", "Docker Desktop cache", group: vm),
        ])

        notes.append(L("Docker Desktop: muốn thu nhỏ file ổ đĩa ảo (Docker.raw) vào Settings → Resources → Disk usage limit."))
        return ScanResult(items: items, notes: notes)
    }

    /// One line each: {"Type":"Images","Reclaimable":"1.2GB (45%)",…}
    private func parseDockerDF(_ output: String, tool: String) -> [CleanItem] {
        var items: [CleanItem] = []
        let group = tool == "docker" ? "Docker" : "Podman"
        for line in output.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["Type"] as? String else { continue }
            let reclaim = ByteFormat.parse(obj["Reclaimable"] as? String ?? "0B")
            let total = obj["Size"] as? String ?? "?"
            let count = L("\(String(describing: obj["TotalCount"] ?? "?")) mục, \(String(describing: obj["Active"] ?? "?")) đang dùng, tổng \(total)")
            guard reclaim > 0 else { continue }

            let (title, args, safety, note): (String, [String], Safety, String) = switch type {
            case "Images":
                (L("Image không dùng"), ["image", "prune", "-a", "-f"], .caution,
                 L("Xoá mọi image không gắn với container nào — lần sau sẽ pull lại"))
            case "Containers":
                (L("Container đã dừng"), ["container", "prune", "-f"], .caution,
                 L("Xoá container đã stop (dữ liệu trong container, không phải volume, sẽ mất)"))
            case "Local Volumes":
                (L("Volume không dùng"), ["volume", "prune", "-a", "-f"], .danger,
                 L("CẨN THẬN: volume có thể chứa dữ liệu database. Chỉ xoá volume không gắn container nào."))
            case "Build Cache":
                ("Build cache", ["builder", "prune", "-a", "-f"], .safe,
                 L("Cache của docker build / BuildKit — build lần sau chậm hơn"))
            default:
                (type, [], .caution, "")
            }
            guard !args.isEmpty else { continue }
            let adjustedArgs = tool == "podman" && type == "Build Cache"
                ? ["system", "prune", "-f"] : args
            items.append(ScanKit.commandItem(
                id: "cmd:\(tool)-\(type)", title: title, group: group,
                command: ShellCommand(executable: tool, arguments: adjustedArgs),
                size: reclaim, safety: safety, note: note, detail: count))
        }
        return items
    }
}
