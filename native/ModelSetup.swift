import Foundation

struct DownloadModel: Decodable {
    struct File: Decodable { let name: String; let size: Int64; let sha256: String }
    let key: String, name: String, title: String, repo: String, revision: String, license: String
    let bits: Int
    let bytes: Int64
    let files: [File]
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
    private(set) var failed = false
    private var process: Process?
    private var cancelled = false
    init(support: URL, resources: URL) {
        self.support = support; self.resources = resources
        let data = try? Data(contentsOf: resources.appendingPathComponent("setup/catalog.json"))
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
    func start(config: [String: Any], only: String = "all") {
        guard !busy, ["all","asrModel","cleanupModel"].contains(only) else { return }
        guard !models.isEmpty else { message = "安装包缺少模型清单，请重新构建。"; failed = true; onChange?(); return }
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [resources.appendingPathComponent("setup/bootstrap.sh").path, support.path, config["python"] as? String ?? "", only]
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
            process = task; busy = true; failed = false; cancelled = false; fraction = nil; message = "正在检查运行环境…"; onChange?()
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
                    self.process = nil; self.busy = false
                    if self.cancelled { self.message = "已取消。已下载的模型片段会在重试时继续。"; self.fraction = nil }
                    else if task.terminationStatus == 0 { self.message = "文件校验完成，正在加载本地模型…"; self.fraction = 1; self.onComplete?() }
                    else { self.failed = true; if !self.message.hasPrefix("下载失败") { self.message = "下载未完成。请检查网络或可用空间后重试；详情在 setup.log。" } }
                    self.onChange?()
                }
            }
        } catch { message = "无法开始下载：\(error.localizedDescription)"; failed = true; onChange?() }
    }
    private func receive(_ event: [String: Any]) {
        if let text = event["message"] as? String { message = text }
        if event["event"] as? String == "error" { message = "下载失败：\(message)"; failed = true }
        if let completed = event["completed"] as? Double, let total = event["total"] as? Double, total > 0 {
            fraction = min(1,max(0,completed/total))
            if event["stage"] as? String == "download" {
                let format = ByteCountFormatter(); format.countStyle = .file
                message += "\n\(format.string(fromByteCount:Int64(completed))) / \(format.string(fromByteCount:Int64(total)))"
            }
        } else { fraction = nil }
        onChange?()
    }
    func cancel() {
        guard busy else { return }
        cancelled = true; message = "正在取消…"; onChange?(); process?.terminate()
    }
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
