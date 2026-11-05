import AppKit
@preconcurrency import Sparkle

/// Sparkle owns transport, signature verification, staging and replacement.
/// This driver keeps the interaction in freetalk's settings page.
final class AppUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Phase { case idle, checking, available, downloading, extracting, ready, installing, failed, installed }
    private(set) var phase = Phase.idle
    private(set) var message = "自动检查已发布的版本，点击后才下载。"
    private(set) var version: String?
    private(set) var notes = ""
    private(set) var fraction: Double?
    private(set) var progressText = ""
    private(set) var engine: SPUUpdater!
    var onChange: (() -> Void)?
    var onFocus: (() -> Void)?
    var canInstall: () -> Bool = { true }
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var received: UInt64 = 0, expected: UInt64 = 0
    private var cancelled = false
    private var informational = false
    private var started = false
    private var checkObservation: NSKeyValueObservation?
    var installing: Bool { phase == .installing }
    var hasUpdate: Bool { [.available,.downloading,.extracting,.ready].contains(phase) }
    var canCancel: Bool { cancellation != nil || installReply != nil || updateReply != nil }
    var automatic: Bool { engine.automaticallyChecksForUpdates }
    var lastChecked: Date? { engine.lastUpdateCheckDate }
    var primaryTitle: String {
        switch phase {
        case .available: return informational ? "查看版本说明" : "下载更新"
        case .ready: return "安装并重启"
        case .checking: return "正在检查…"
        case .downloading: return "正在下载…"
        case .extracting: return "正在校验…"
        case .installing: return "正在安装…"
        default: return "检查更新"
        }
    }
    var primaryEnabled: Bool {
        if phase == .ready { return canInstall() }
        if phase == .available { return true }
        return engine.canCheckForUpdates && ![.checking,.downloading,.extracting,.installing].contains(phase)
    }
    init(bundle: Bundle = .main) {
        super.init()
        engine = SPUUpdater(hostBundle:bundle,applicationBundle:bundle,userDriver:self,delegate:self)
        checkObservation = engine.observe(\.canCheckForUpdates,options:[.new]) { [weak self] _,_ in
            DispatchQueue.main.async { self?.onChange?() }
        }
    }
    func start(checkAtLaunch: Bool = true) {
        guard !started else { return }
        do {
            try engine.start(); started = true
            if checkAtLaunch && automatic { engine.checkForUpdatesInBackground() }
        } catch { fail(error) }
        onChange?()
    }
    func setAutomatic(_ value: Bool) { engine.automaticallyChecksForUpdates = value; onChange?() }
    func check() {
        if hasUpdate { onFocus?(); return }
        guard engine.canCheckForUpdates else { return }
        cancelled = false; phase = .checking; message = "正在检查 GitHub 发布的版本…"
        onChange?(); engine.checkForUpdates()
    }
    func primaryAction() {
        if phase == .available, informational {
            NSWorkspace.shared.open(URL(string:"https://github.com/Zacklinkk/freetalk/releases")!); return
        }
        if phase == .available, let reply = updateReply {
            cancelled = false; updateReply = nil; phase = .downloading
            message = "正在下载更新…"; onChange?(); reply(.install); return
        }
        if phase == .ready, let reply = installReply {
            guard canInstall() else { message = "请等待当前录音、文字处理或模型下载完成，再安装更新。"; onChange?(); return }
            installReply = nil; phase = .installing; message = "正在安装，freetalk 将自动重新打开…"
            onChange?(); reply(.install); return
        }
        check()
    }
    func cancel() {
        guard canCancel else { return }
        cancelled = true
        let cancel = cancellation, install = installReply, update = updateReply
        cancellation = nil; installReply = nil; updateReply = nil
        phase = .idle; fraction = nil; progressText = ""; version = nil
        message = "已取消更新，当前版本继续使用。"
        // Skip at the ready stage cancels this installation without skipping the version.
        if let install = install { install(.skip) }
        else if let cancel = cancel { cancel() }
        else { update?(.dismiss) }
        onChange?()
    }
    private func fail(_ error: Error) {
        guard !cancelled else { return }
        if (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == Int(SUError.noUpdateError.rawValue) {
            notFound(error); return
        }
        cancellation = nil; updateReply = nil; installReply = nil
        phase = .failed; fraction = nil; progressText = ""
        let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
        message = "更新未完成：\(reason)\n当前版本仍可使用，可稍后重试。"; onChange?()
    }
    private func notFound(_ error: Error) {
        guard !cancelled else { return }
        cancellation = nil; updateReply = nil; installReply = nil
        phase = .idle; version = nil; notes = ""; fraction = nil; progressText = ""
        message = (error as NSError).localizedRecoverySuggestion ?? "当前没有可安装的新版本。"
        onChange?()
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Defaults are declared in Info.plist and the user can turn checks off in settings.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks:automatic,sendSystemProfile:false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; phase = .checking; message = "正在检查 GitHub 发布的版本…"; onChange?()
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil; updateReply = nil; installReply = nil; informational = appcastItem.isInformationOnlyUpdate
        version = appcastItem.displayVersionString; notes = String((appcastItem.itemDescription ?? "").prefix(12000))
        phase = state.stage == .installing ? .ready : .available
        if phase == .ready { installReply = reply } else { updateReply = reply }
        fraction = nil; progressText = ""; cancelled = false
        message = "发现新版本 \(appcastItem.displayVersionString)"; onChange?()
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { notFound(error); acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { fail(error); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; phase = .downloading; received = 0; expected = 0
        fraction = nil; progressText = ""; message = "正在下载更新…"; onChange?()
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength; downloadProgress() }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received = length > UInt64.max-received ? UInt64.max : received+length; downloadProgress()
    }
    private func downloadProgress() {
        let downloaded = ByteCountFormatter.string(fromByteCount:Int64(min(received,UInt64(Int64.max))),countStyle:.file)
        if expected > 0 {
            fraction = min(1,Double(received)/Double(expected))
            progressText = String(format:"%.1f%%",fraction!*100) + " · \(downloaded) / \(ByteCountFormatter.string(fromByteCount:Int64(min(expected,UInt64(Int64.max))),countStyle:.file))"
        } else { fraction = nil; progressText = "已下载 \(downloaded)" }
        onChange?()
    }
    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil; phase = .extracting; fraction = nil; progressText = ""
        message = "下载完成，正在校验签名并准备安装…"; onChange?()
    }
    func showExtractionReceivedProgress(_ progress: Double) { fraction = progress.isFinite ? min(1,max(0,progress)) : nil; onChange?() }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installReply = reply; phase = .ready; fraction = 1
        message = "更新已准备好。点击安装并重启，或退出应用后完成更新。"; onChange?()
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing; fraction = nil; message = "正在安装并重新打开 freetalk…"; onChange?()
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .installed; fraction = 1; message = "更新安装完成。"; onChange?(); acknowledgement()
    }
    func dismissUpdateInstallation() {
        cancellation = nil; updateReply = nil; installReply = nil
        if [.checking,.downloading,.extracting].contains(phase) { phase = .idle }
        onChange?()
    }
    func showUpdateInFocus() { onFocus?() }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { fail(error) }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { notFound(error) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) { onChange?() }
}
