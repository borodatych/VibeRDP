import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The programs of the host in the Dock and in Cmd-Tab, in the Seam mode: a stand-in app for each, decision 50
///
/// The stand-in is a copy of VibeRDPProxy.app from the bundle of VibeRDP, made in the cache with the name and the
/// icon of the program and signed again, since its Info.plist changed; it has no windows, only the icon
/// Choosing the icon brings the windows of the program forward, quitting it closes them on the host
@MainActor
final class DockProxies {
    /// The names the stand-in posts under, with its bundle identifier as the object
    static let activated = Notification.Name("tech.vibebrains.viberdp.proxy.activated")
    static let quitRequested = Notification.Name("tech.vibebrains.viberdp.proxy.quitRequested")
    nonisolated static let identifierPrefix = "tech.vibebrains.viberdp.proxy."
    nonisolated static let templateName = "VibeRDPProxy.app"
    /// The helper sends the icon right after the window; a program without one gets the stand-in this much later
    static let iconWait: TimeInterval = 1
    /// The sides of the icon in the file: the Dock and Cmd-Tab take them, larger ones would only be scaled up
    nonisolated static let iconSides = [128, 256]

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "tech.vibebrains.viberdp/Proxies", directoryHint: .isDirectory)
    }

    private let template: URL?
    private let onActivate: ([UInt64]) -> Void
    private let onQuit: ([UInt64]) -> Void
    private var groups: [String: DockGroup] = [:]
    /// When each program without a stand-in was first seen
    private var waiting: [String: Date] = [:]
    private var starting: Set<String> = []
    /// The process of each stand-in that runs
    private var running: [String: pid_t] = [:]
    private var observers: [NSObjectProtocol] = []
    private var waitTimer: Timer?

    init(onActivate: @escaping ([UInt64]) -> Void, onQuit: @escaping ([UInt64]) -> Void) {
        template = Bundle.main.sharedSupportURL?.appending(path: Self.templateName, directoryHint: .isDirectory)
        self.onActivate = onActivate
        self.onQuit = onQuit
        let center = DistributedNotificationCenter.default()
        observers = [
            center.addObserver(forName: Self.activated, object: nil, queue: .main) { [weak self] note in
                let key = note.object as? String
                MainActor.assumeIsolated { self?.received(key, quit: false) }
            },
            center.addObserver(forName: Self.quitRequested, object: nil, queue: .main) { [weak self] note in
                let key = note.object as? String
                MainActor.assumeIsolated { self?.received(key, quit: true) }
            },
        ]
    }

    /// The programs as they are now: new ones get a stand-in once their icon is here, gone ones lose theirs
    func update(_ current: [DockGroup]) {
        let now = Date()
        groups = Dictionary(current.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for key in Array(running.keys) + Array(waiting.keys) where groups[key] == nil {
            stop(key)
        }
        for group in current where running[group.key] == nil && !starting.contains(group.key) {
            let since = waiting[group.key] ?? now
            if group.icon != nil || now.timeIntervalSince(since) >= Self.iconWait {
                waiting[group.key] = nil
                start(group)
            } else {
                waiting[group.key] = since
            }
        }
        scheduleWait()
    }

    /// The session or the Seam mode ended: every stand-in goes
    func stopAll() {
        for key in Set(running.keys).union(waiting.keys).union(starting) {
            stop(key)
        }
        groups = [:]
        waitTimer?.invalidate()
        waitTimer = nil
    }

    func invalidate() {
        stopAll()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }

    private func scheduleWait() {
        waitTimer?.invalidate()
        waitTimer = nil
        guard !waiting.isEmpty else { return }
        waitTimer = Timer.scheduledTimer(withTimeInterval: Self.iconWait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update(Array(self.groups.values))
            }
        }
    }

    private func received(_ identifier: String?, quit: Bool) {
        guard let identifier, identifier.hasPrefix(Self.identifierPrefix) else { return }
        let key = String(identifier.dropFirst(Self.identifierPrefix.count))
        guard let group = groups[key] else { return }
        if quit {
            running[key] = nil
            onQuit(group.windows)
        } else {
            onActivate(group.windows)
        }
    }

    private func start(_ group: DockGroup) {
        guard let template else {
            Diagnostics.warning("dock", "no stand-in template in the app bundle")
            return
        }
        starting.insert(group.key)
        let destination = Self.folder.appending(path: "\(group.key).app", directoryHint: .isDirectory)
        let images = group.icon.map { Self.iconImages(from: $0) } ?? [:]
        // Copying and signing take a moment: they run off the main thread, the result comes back to it
        Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                Result { try DockProxyBundle.make(from: template, at: destination, group: group, icons: images) }
            }.value
            self?.built(group, destination, built)
        }
    }

    /// The program stays among the starting ones until the stand-in runs or fails:
    /// an update meanwhile must not start a second one
    private func built(_ group: DockGroup, _ bundle: URL, _ result: Result<Void, Error>) {
        guard starting.contains(group.key), groups[group.key] != nil else {
            starting.remove(group.key)
            return
        }
        if case .failure(let error) = result {
            starting.remove(group.key)
            Diagnostics.warning("dock", "stand-in of \(group.name) not made: \(error)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--parent", String(ProcessInfo.processInfo.processIdentifier)]
        // LaunchServices answers on a queue of its own: the answer goes over to the main thread
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { [weak self] app, error in
            let process = app?.processIdentifier
            let failure = error.map { String(describing: $0) }
            Task { @MainActor [weak self] in
                self?.launched(group, process: process, failure: failure)
            }
        }
    }

    private func launched(_ group: DockGroup, process: pid_t?, failure: String?) {
        let wanted = starting.remove(group.key) != nil && groups[group.key] != nil
        guard let process else {
            Diagnostics.warning("dock", "stand-in of \(group.name) not started: \(failure ?? "no process")")
            return
        }
        if wanted {
            running[group.key] = process
            Diagnostics.info("dock", "stand-in of \(group.name) started")
        } else {
            Self.end(process)
        }
    }

    /// Whether the stand-in of a program runs, for the tests
    func isRunning(_ key: String) -> Bool {
        running[key] != nil
    }

    /// A stand-in still starting is told to go once it runs: launched sees it no longer wanted
    private func stop(_ key: String) {
        waiting[key] = nil
        starting.remove(key)
        if let process = running.removeValue(forKey: key) {
            Self.end(process)
        }
    }

    /// Quits a stand-in the way the Dock would: a notification could come before the stand-in listens,
    /// a quit event waits for it; its own quit is then not the user's, and VibeRDP no longer knows the program
    private static func end(_ process: pid_t) {
        NSRunningApplication(processIdentifier: process)?.terminate()
    }

    /// The icon of the host at the sides of the file, redrawn from the PNG the helper sent
    nonisolated static func iconImages(from png: Data) -> [Int: Data] {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [:] }
        var images: [Int: Data] = [:]
        for side in iconSides {
            guard
                let context = CGContext(
                    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            guard let scaled = context.makeImage() else { continue }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(destination, scaled, nil)
            if CGImageDestinationFinalize(destination) {
                images[side] = data as Data
            }
        }
        return images
    }
}

/// Makes the bundle of a stand-in: the template copied, its Info.plist renamed, the icon added, signed again
enum DockProxyBundle {
    enum Failure: Error {
        case infoPlist
        case signature(Int32)
    }

    static let iconFile = "AppIcon"

    static func make(from template: URL, at destination: URL, group: DockGroup, icons: [Int: Data]) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) {
            try files.removeItem(at: destination)
        }
        try files.copyItem(at: template, to: destination)

        let infoURL = destination.appending(path: "Contents/Info.plist")
        guard
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
                as? [String: Any]
        else { throw Failure.infoPlist }
        info["CFBundleIdentifier"] = DockProxies.identifierPrefix + group.key
        info["CFBundleName"] = group.name
        info["CFBundleDisplayName"] = group.name
        info.removeValue(forKey: "CFBundleIconName")
        if let icns = IconFile.icns(icons) {
            let resources = destination.appending(path: "Contents/Resources", directoryHint: .isDirectory)
            try files.createDirectory(at: resources, withIntermediateDirectories: true)
            try icns.write(to: resources.appending(path: "\(iconFile).icns"))
            info["CFBundleIconFile"] = iconFile
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)

        // The Info.plist is sealed by the signature of the template: the copy is signed again, ad hoc as VibeRDP
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--timestamp=none", destination.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else { throw Failure.signature(codesign.terminationStatus) }
    }
}
