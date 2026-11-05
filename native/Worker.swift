import Foundation

final class VoiceWorker {
    private var process: Process?
    private var writer: FileHandle?
    private var buffer = Data()
    private let readQueue = DispatchQueue(label: "local.voice.worker.read")
    private let writeQueue = DispatchQueue(label: "local.voice.worker.write")
    private var callbacks: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var counter = 0
    private var generation = UUID()
    private var watchdog: Timer?
    private(set) var ready = false
    var onState: ((String, Bool) -> Void)?
    var onPartial: ((String) -> Void)?
    var onStage: ((String) -> Void)?
    var onMeetingProgress: (([String: Any]) -> Void)?

    func start(config: [String: Any], resource: URL, support: URL) {
        stop()
        let token = generation
        guard let python = config["python"] as? String, FileManager.default.isExecutableFile(atPath: python) else {
            onState?("未找到 Python 环境，请检查本地配置", false); return
        }
        let task = Process(), input = Pipe(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = ["-u", resource.appendingPathComponent("python/worker.py").path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"
        env["MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS"] = "1000"
        env["PYTHONUNBUFFERED"] = "1"; env["TOKENIZERS_PARALLELISM"] = "false"
        env["PYTHONDONTWRITEBYTECODE"] = "1" // Keep the signed app bundle immutable.
        task.environment = env
        task.standardInput = input; task.standardOutput = output
        let log = support.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        task.standardError = try? FileHandle(forWritingTo: log)
        task.terminationHandler = { [weak self] p in DispatchQueue.main.async {
            guard let self = self, self.generation == token else { return }
            self.ready = false; self.watchdog?.invalidate()
            let pending = self.callbacks; self.callbacks.removeAll()
            for callback in pending.values { callback(.failure(VoiceError.message("模型进程已结束（\(p.terminationStatus)）"))) }
            self.onState?("模型进程已结束，请点重新加载", false)
        } }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.readQueue.async { [weak self] in
                guard let self = self else { return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<end]; self.buffer.removeSubrange(...end)
                    guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    DispatchQueue.main.async { if self.generation == token { self.receive(item) } }
                }
            }
        }
        do {
            try task.run(); process = task; writer = input.fileHandleForWriting
            var startupConfig = config
            startupConfig["inferenceLockPath"] = support.appendingPathComponent("inference.lock").path
            write(startupConfig)
            onState?("正在加载本地模型…", false)
            watchdog = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
                guard let self = self, self.generation == token, !self.ready else { return }
                self.stop(); self.onState?("模型加载超时，请点重新加载", false)
            }
        } catch { onState?(error.localizedDescription, false) }
    }

    private func receive(_ item: [String: Any]) {
        if item["event"] as? String == "meeting-progress" { onMeetingProgress?(item) }
        if item["event"] as? String == "ready" { ready = true; watchdog?.invalidate(); onState?("本地模型已就绪", true) }
        if item["event"] as? String == "partial", let text = item["text"] as? String { onPartial?(text) }
        if item["event"] as? String == "model-request", let stage = item["stage"] as? String { onStage?(stage) }
        // Prompt/debug events deliberately stay in memory and are never logged.
        if let id = item["id"] as? Int, let callback = callbacks.removeValue(forKey: id) {
            if let error = item["error"] as? String { callback(.failure(VoiceError.message(error))) }
            else { callback(.success(item["result"] as? [String: Any] ?? [:])) }
        }
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let writer = writer else { return }
        writeQueue.async { try? writer.write(contentsOf: data + Data([10])) }
    }

    func request(_ action: String, _ payload: [String: Any] = [:], completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        guard ready else { completion?(.failure(VoiceError.message("模型尚未就绪"))); return }
        counter += 1; var object = payload; object["action"] = action; object["id"] = counter
        if let completion = completion { callbacks[counter] = completion }
        write(object)
    }

    func stop() {
        generation = UUID(); ready = false; watchdog?.invalidate(); watchdog = nil
        callbacks.removeAll(); try? writer?.close(); writer = nil
        if let process = process, process.isRunning { process.terminate() }
        process = nil
        readQueue.sync { buffer.removeAll() }
    }
    deinit { stop() }
}
