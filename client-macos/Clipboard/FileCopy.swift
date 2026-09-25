import AppKit
import VibeRDPCore
import os

/// The progress of a copy of remote files, shared by the thread that copies and the window that shows it
/// The end of the copy comes here too, not through the main queue:
/// a paste may wait inside a block of the main queue, and a nested run loop does not drain that queue again
final class FileCopyProgress: Sendable {
    private struct State {
        var done: UInt64 = 0
        var total: UInt64 = 0
        var cancelled = false
        var result: VRCResult?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Bytes written so far and the bytes of all the files
    var bytes: (done: UInt64, total: UInt64) {
        state.withLock { ($0.done, $0.total) }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    /// From the thread that copies; false once the copy is cancelled
    func report(done: UInt64, total: UInt64) -> Bool {
        state.withLock {
            $0.done = done
            $0.total = total
            return !$0.cancelled
        }
    }

    /// How the copy ended, nil while it runs
    var result: VRCResult? {
        state.withLock { $0.result }
    }

    /// From the thread that copies, once, when the copy ends
    func finish(_ result: VRCResult) {
        state.withLock { $0.result = result }
    }
}

/// Holds a paste of remote files on the main thread until their copy ends, and tells the user how it went
@MainActor
protocol FileCopyWaiter: AnyObject {
    /// Returns once the copy has a result; it may have one before the wait starts
    func wait(for progress: FileCopyProgress)
    /// The copy failed for a reason other than the user's cancel
    func copyFailed()
}

/// Folders for the files of the remote clipboard, one for each remote copy, in the caches of the app
struct FileStaging {
    /// A folder left by a session that did not end cleanly is removed after a day, when no paste can need it
    static let staleAge: TimeInterval = 24 * 60 * 60
    static let defaultRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: Bundle.main.bundleIdentifier ?? "tech.vibebrains.viberdp", directoryHint: .isDirectory)
        .appending(path: "Clipboard", directoryHint: .isDirectory)

    let root: URL

    init(root: URL = Self.defaultRoot) {
        self.root = root
    }

    func makeFolder() -> URL? {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    func removeStale(now: Date = Date()) {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > Self.staleAge {
                remove(folder)
            }
        }
    }
}

/// A small window over the app while files come from the remote computer: how much, and a way to stop
/// It shows only when the copy takes a while, so a small file pastes without a flash
@MainActor
final class FileCopyPanel: NSObject, FileCopyWaiter {
    /// Copies shorter than this end before the window shows
    static let appearDelay: TimeInterval = 0.5
    static let refreshInterval: TimeInterval = 0.1
    static let width: CGFloat = 360
    static let spacing: CGFloat = 12
    static let margin: CGFloat = 20

    /// The copy the panel shows, for its Cancel button
    private var progress: FileCopyProgress?

    func wait(for progress: FileCopyProgress) {
        guard progress.result == nil else { return }
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        let detail = NSTextField(labelWithString: "")
        let panel = makePanel(bar: bar, detail: detail)
        self.progress = progress
        panel.alphaValue = 0
        panel.center()

        let started = Date()
        // The modal mode runs only modal sources: the timer must be in it to fire during the wait
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                // abortModal ends the modal loop from a timer, stopModal only from an event
                if progress.result != nil {
                    NSApp.abortModal()
                    return
                }
                let bytes = progress.bytes
                bar.doubleValue = bytes.total > 0 ? Double(bytes.done) / Double(bytes.total) : 0
                detail.stringValue = Localization.text(
                    .clipboardFilesProgress,
                    ["done": Self.size(bytes.done), "total": Self.size(bytes.total)])
                if Date().timeIntervalSince(started) >= Self.appearDelay {
                    panel.alphaValue = 1
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.runModal(for: panel)
        timer.invalidate()
        panel.orderOut(nil)
        self.progress = nil
    }

    func copyFailed() {
        let alert = NSAlert()
        alert.messageText = Localization.text(.clipboardFilesFailed)
        alert.runModal()
    }

    /// The copy stops at its next range, and the wait ends when it does
    @objc private func cancel() {
        progress?.cancel()
    }

    private func makePanel(bar: NSProgressIndicator, detail: NSTextField) -> NSPanel {
        let title = NSTextField(labelWithString: Localization.text(.clipboardFilesCopying))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        detail.textColor = .secondaryLabelColor
        let cancel = NSButton(title: Localization.text(.clipboardFilesCancel), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [title, bar, detail, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.spacing
        stack.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        stack.setCustomSpacing(Self.spacing * 2, after: detail)
        bar.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = stack
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
