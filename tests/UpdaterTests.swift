import AppKit
import Sparkle

@main struct UpdaterTests {
    static func main() {
        let updater = AppUpdater()
        var cancelled = false
        updater.showDownloadInitiated { cancelled = true }
        updater.showDownloadDidReceiveData(ofLength:128)
        precondition(updater.fraction == nil && !updater.progressText.isEmpty)
        updater.showDownloadDidReceiveExpectedContentLength(256)
        precondition(updater.fraction == 0.5)
        updater.showDownloadDidReceiveData(ofLength:UInt64.max)
        precondition(updater.fraction == 1)
        updater.cancel()
        precondition(cancelled && updater.phase == .idle && !updater.canCancel)

        // Installing must never terminate the host during dictation or a model download.
        let guarded = AppUpdater()
        var choice: SPUUserUpdateChoice?
        guarded.canInstall = { false }
        guarded.showReady { choice = $0 }
        guarded.primaryAction()
        precondition(choice == nil && guarded.phase == .ready && !guarded.primaryEnabled)
        guarded.canInstall = { true }
        guarded.primaryAction()
        precondition(choice == .install && guarded.installing)

        let discard = AppUpdater()
        choice = nil
        discard.showReady { choice = $0 }
        discard.cancel()
        precondition(choice == .skip && discard.phase == .idle)

        let latest = AppUpdater()
        latest.updater(latest.engine,didAbortWithError:NSError(domain:SUSparkleErrorDomain,code:Int(SUError.noUpdateError.rawValue)))
        precondition(latest.phase == .idle) // Sparkle also reports "no update" through didAbort.
        var acknowledged = false
        latest.showUpdaterError(NSError(domain:NSURLErrorDomain,code:NSURLErrorNotConnectedToInternet)) { acknowledged = true }
        precondition(latest.phase == .failed && acknowledged && !latest.canCancel)
        print("Updater passed: unknown/known progress, overflow, cancellation, busy restart guard, ready cancellation, no-update and network-error states")
    }
}
