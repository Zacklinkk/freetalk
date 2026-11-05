import Foundation

enum ModelDownloadSource: String, CaseIterable {
    case official, mirror
    var title: String { self == .official ? "Hugging Face 官方" : "HF-Mirror（第三方镜像）" }
    var endpoint: String { self == .official ? "https://huggingface.co" : "https://hf-mirror.com" }
    static var preferred: Self { Self(rawValue:UserDefaults.standard.string(forKey:"modelDownloadSourceV1") ?? "") ?? .official }
}

struct DownloadModel: Decodable {
    struct File: Decodable { let name: String; let size: Int64; let sha256: String }
    let key: String, name: String, title: String, repo: String, revision: String, license: String
    let bits: Int
    let bytes: Int64
    let files: [File]
    func pageURL(source: ModelDownloadSource) -> URL? { URL(string:"\(source.endpoint)/\(repo)/tree/\(revision)") }
    func filesPresent(config: [String: Any]) -> Bool {
        guard let path = config[key] as? String else { return false }
        return files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).appendingPathComponent(file.name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }
}

/// The setup process is the only component that downloads assets. Inference stays offline.
final class ModelSetup {
    struct Catalog: Decodable { let schema: Int; let models: [DownloadModel] }
    let support: URL, resources: URL
    let models: [DownloadModel]
    var onChange: (() -> Void)?
    var onComplete: (() -> Void)?
    private(set) var busy = false
    private(set) var message = "下载一次，之后离线使用。"
    private(set) var fraction: Double?
    private var byteProgress = "", transferProgress = ""
    var progressText: String {
        // A stopped or stalled transfer must not keep advertising its last speed.
        byteProgress + (busy && !failed && Date().timeIntervalSince(lastEvent) < 8 ? transferProgress : "")
    }
    private(set) var failed = false
    private var process: Process?
    private var cancelled = false
    private var ticker: Timer?
    private var started = Date(), lastEvent = Date()
    private var stage = ""
    var activityText: String {
        guard busy else { return "" }
        let elapsed = Int(Date().timeIntervalSince(started)), quiet = Int(Date().timeIntervalSince(lastEvent))
        let elapsedText = elapsed < 60 ? "已进行 \(elapsed) 秒" : "已进行 \(elapsed/60) 分 \(elapsed%60) 秒"
        if quiet >= 8 && ["download","connecting","retry"].contains(stage) {
            return elapsedText + " · \(quiet) 秒未收到新进度，正在等待网络响应；可取消后切换来源。"
        }
        return elapsedText + (stage == "runtime" ? " · 正在准备运行环境，当前阶段没有可用的总字节数。" : "")
    }
    init(support: URL, resources: URL, catalogName: String = "catalog.json") {
        self.support = support; self.resources = resources
        let data = try? Data(contentsOf: resources.appendingPathComponent("setup/\(catalogName)"))
        models = data.flatMap { try? JSONDecoder().decode(Catalog.self, from: $0).models } ?? []
    }
    static func configured(_ config: [String: Any]) -> Bool {
        guard let python = config["python"] as? String, FileManager.default.isExecutableFile(atPath: python) else { return false }
        return ["asrModel", "cleanupModel"].allSatisfy { key in
            guard let path = config[key] as? String else { return false }
            let directory = URL(fileURLWithPath: path)
            return ["config.json", "model.safetensors", "tokenizer_config.json"].allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        }
    }
    func start(config: [String: Any], only: String = "all", source: ModelDownloadSource = .official) {
        guard !busy, only == "all" || models.contains(where: { $0.key == only }) else { return }
        guard !models.isEmpty else { message = "安装包缺少模型清单，请重新构建。"; failed = true; onChange?(); return }
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [resources.appendingPathComponent("setup/bootstrap.sh").path, support.path, config["python"] as? String ?? "", only, source.rawValue]
        var env = ProcessInfo.processInfo.environment
        for key in ["HF_TOKEN","HUGGING_FACE_HUB_TOKEN","HF_ENDPOINT","PYTHONPATH","PYTHONHOME","VIRTUAL_ENV","UV_INDEX_URL","UV_EXTRA_INDEX_URL","PIP_INDEX_URL","PIP_EXTRA_INDEX_URL"] { env.removeValue(forKey:key) }
        env["PYTHONDONTWRITEBYTECODE"] = "1"; env["HF_HUB_OFFLINE"] = "0"; env["TRANSFORMERS_OFFLINE"] = "0"
        env["PYTHONUNBUFFERED"] = "1"; task.environment = env; task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let log = support.appendingPathComponent("setup.log")
            try Data().write(to: log, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
            task.standardError = try FileHandle(forWritingTo: log)
            try task.run()
            process = task; busy = true; failed = false; cancelled = false; fraction = nil; byteProgress = ""; transferProgress = ""
            started = Date(); lastEvent = started; stage = "runtime"; message = "正在检查运行环境…"
            ticker?.invalidate(); ticker = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.onChange?() }
            onChange?()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var buffer = Data()
                let reader = output.fileHandleForReading
                while true {
                    let data = reader.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                        if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            DispatchQueue.main.async { self?.receive(event) }
                        }
                    }
                }
                task.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.process = nil; self.busy = false; self.ticker?.invalidate(); self.ticker = nil
                    if self.cancelled { self.message = "已取消。已下载的模型片段会在重试时继续。"; self.fraction = nil }
                    else if task.terminationStatus == 0 { self.message = "文件校验完成，正在加载本地模型…"; self.fraction = 1; self.onComplete?() }
                    else { self.failed = true; if !self.message.hasPrefix("下载失败") { self.message = "下载未完成。请查看下载日志；模型连接失败时可切换官方源或镜像后重试。" } }
                    self.onChange?()
                }
            }
        } catch { message = "无法开始下载：\(error.localizedDescription)"; failed = true; onChange?() }
    }
    private func receive(_ event: [String: Any]) {
        lastEvent = Date(); stage = event["stage"] as? String ?? stage
        transferProgress = ""
        if let text = event["message"] as? String { message = text }
        if event["event"] as? String == "error" { message = "下载失败：\(message)"; failed = true }
        if let completed = event["completed"] as? Double, let total = event["total"] as? Double, total > 0,
           completed.isFinite, total.isFinite, completed >= 0, total < Double(Int64.max/2) {
            fraction = min(1,max(0,completed/total))
            let format = ByteCountFormatter(); format.countStyle = .file
            byteProgress = String(format:"%.1f%%",fraction!*100) + " · \(format.string(fromByteCount:Int64(min(completed,total)))) / \(format.string(fromByteCount:Int64(total)))"
            if stage == "download", let speed = event["bytes_per_second"] as? Double, speed.isFinite, speed > 0, speed < Double(Int64.max/2) {
                transferProgress += " · \(format.string(fromByteCount:Int64(speed)))/s"
                if let eta = event["eta_seconds"] as? Double, eta.isFinite, eta > 0, eta < 86400*365 {
                    let seconds = Int(eta)
                    transferProgress += seconds < 60 ? " · 预计剩余 \(seconds) 秒" : " · 预计剩余 \(seconds/60) 分钟"
                }
            }
        } else if event["event"] as? String != "error" { fraction = nil; byteProgress = "" }
        onChange?()
    }
    func cancel() {
        guard busy else { return }
        cancelled = true; message = "正在取消…"; onChange?(); process?.terminate()
    }
    deinit { ticker?.invalidate() }
}

enum LegacyMigration {
    /// Copy small user files once; keep existing model paths and the old copy intact.
    static func migrate(from legacy: URL, to support: URL) throws {
        let manager = FileManager.default
        guard legacy != support, manager.fileExists(atPath: legacy.appendingPathComponent("config.json").path),
              !manager.fileExists(atPath: support.appendingPathComponent(".legacy-imported").path) else { return }
        try manager.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        for name in ["config.json","history.json","last-result.json","dictionary.json","dictionary-aliases.json","correction-suggestions.json"] {
            let source = legacy.appendingPathComponent(name), destination = support.appendingPathComponent(name)
            if manager.fileExists(atPath: source.path), !manager.fileExists(atPath: destination.path) {
                try manager.copyItem(at: source, to: destination)
                try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            }
        }
        try Data("Imported existing files without overwriting user data.\n".utf8).write(to:support.appendingPathComponent(".legacy-imported"),options:.atomic)
    }
}
