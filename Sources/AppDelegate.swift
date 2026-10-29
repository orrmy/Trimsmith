import AppKit

/// Routes Finder/Dock opens to the single editor and coordinates cancellation before quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var editor: EditorModel? {
        didSet {
            if let pendingURLs, editor != nil {
                self.pendingURLs = nil
                openURLs(pendingURLs)
            }
        }
    }
    private var pendingURLs: [URL]?
    private var terminating = false

    /// Forwards the system’s file-open event to the existing editing session.
    func application(_ application: NSApplication, open urls: [URL]) { openURLs(urls) }

    /// Queues early launch events until the editor attaches, then opens one source at a time.
    func openURLs(_ urls: [URL]) {
        guard !urls.isEmpty, !terminating else { return }
        guard let editor else { pendingURLs = urls; return }
        guard urls.count == 1 else {
            editor.error = "Open one video at a time. Trimsmith keeps segments from a single source file."
            return
        }
        editor.open(urls[0])
    }
    /// Treats closing the only editor window as quitting the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// Defers termination until the editor has cancelled work and finished export cleanup.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        pendingURLs = nil
        Task {
            await editor?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
