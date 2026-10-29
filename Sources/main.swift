import AppKit
import ApplicationServices
import Darwin

@MainActor
final class DemoController: NSObject, NSApplicationDelegate {
    private let index = RecentFileIndex()
    private let folderAccess = FolderAccessStore()
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var overlays: [DragOverlayPanel] = []
    private var controlWindow: ControlWindowController!
    private var statusText = "启动中"
    private var hideDockWhenClosed = true
    private var currentSignature = ""
    private var lastSnapshot: DockProbeSnapshot?
    private var lastExpandedSnapshot: DockProbeSnapshot?
    private var running = false
    private var interacting = false
    private var dragging = false
    private var promptedForFolders = false
    private var showDebugFrames = false
    private var log: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["hideDockWhenWindowClosed": true])
        hideDockWhenClosed = UserDefaults.standard.bool(forKey: "hideDockWhenWindowClosed")
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        if let icon { NSApp.applicationIconImage = icon }
        controlWindow = ControlWindowController(icon: icon) { [weak self] action in self?.handle(action) }
        installApplicationMenu()
        showControlWindow()
        start()
        if !AXIsProcessTrusted() { requestAccess() }
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Recents Drag")
        for (title, action, key) in [("显示控制窗口", #selector(showControlWindow), ","),
                                     ("关闭窗口", #selector(NSWindow.performClose(_:)), "w"),
                                     ("完全退出", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if key != "w" { item.target = self }
            appMenu.addItem(item)
        }
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"),
                                     ("重做", Selector(("redo:")), "Z"),
                                     ("剪切", #selector(NSText.cut(_:)), "x"),
                                     ("复制", #selector(NSText.copy(_:)), "c"),
                                     ("粘贴", #selector(NSText.paste(_:)), "v"),
                                     ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func showControlWindow() {
        hideOverlays()
        NSApp.setActivationPolicy(.regular)
        renderState()
        controlWindow.window?.deminiaturize(nil)
        controlWindow.showWindow(nil)
        controlWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func handle(_ action: ControlAction) {
        switch action {
        case .toggleRunning: toggle()
        case .chooseFolders: chooseFolders()
        case .replaceFolders(let paths): replaceFolders(paths)
        case .forgetFolders: forgetFolders()
        case .debugFrames(let enabled): toggleDebugFrames(enabled)
        case .hideDockWhenClosed(let enabled):
            hideDockWhenClosed = enabled
            UserDefaults.standard.set(enabled, forKey: "hideDockWhenWindowClosed")
            renderState()
        case .requestAccess: requestAccess()
        case .exportDiagnostics: saveDiagnostics()
        case .quit: quit()
        case .windowClosed:
            NSApp.setActivationPolicy(hideDockWhenClosed ? .accessory : .regular)
        }
    }

    private func start() {
        running = true
        do { try folderAccess.restoreAndStart() }
        catch { record("恢复文件夹失败：\(error.localizedDescription)") }
        startFileIndex()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.1
        RunLoop.main.add(timer!, forMode: .common)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideOverlays() }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideOverlays() }
            })
        }
        refresh()
    }

    private func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        index.stop()
        folderAccess.suspend()
        interacting = false
        hideOverlays()
        clearSnapshots()
        setStatus("已停用")
    }

    @objc private func toggle() { running ? stop() : start() }
    private func toggleDebugFrames(_ enabled: Bool) {
        showDebugFrames = enabled
        clearSnapshots()
        hideOverlays()
        renderState()
        refresh()
    }
    @objc private func chooseFolders() {
        promptedForFolders = true
        hideOverlays()
        interacting = true
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            interacting = false
            previousApp?.activate(options: [])
            renderState()
            refresh()
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "授权并记住"
        panel.message = "选择文件所在的“下载”“文稿”或具体工作目录，不要只选择用户主目录。之后自动获取其中的最近文件；可在控制窗口中忘记这些文件夹。"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            index.stop()
            do {
                try folderAccess.add(panel.urls)
                record("已记住 \(folderAccess.storedURLs.count) 个工作文件夹")
            } catch { showError("文件夹访问失败", error) }
            if running { startFileIndex() } else { folderAccess.suspend() }
        }
    }
    @objc private func forgetFolders() {
        promptedForFolders = true
        index.stop()
        hideOverlays()
        clearSnapshots()
        do {
            try folderAccess.forget()
            record("已忘记工作文件夹，停止访问和检索")
        } catch { showError("文件夹访问失败", error) }
        if running { startFileIndex() }
        renderState()
        refresh()
    }
    private func replaceFolders(_ paths: [String]) {
        promptedForFolders = true
        hideOverlays()
        interacting = true
        index.stop()
        clearSnapshots()
        defer {
            if running { startFileIndex() } else { folderAccess.suspend() }
            interacting = false
            renderState()
            refresh()
        }
        do {
            var urls = try paths.map { path -> URL in
                let expanded = (path as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInvalidFileNameError,
                        userInfo: [NSLocalizedDescriptionKey: "每行填写一个完整文件夹路径，支持 ~/ 开头：\n\(path)"])
                }
                let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
                return folderAccess.storedURLs.first(where: { $0.standardizedFileURL.path == url.path }) ?? url
            }
            var confirmed = Set<String>()
            while true {
                do {
                    try folderAccess.replace(urls)
                    break
                } catch {
                    let failure = error as NSError
                    let denied = (failure.domain == NSPOSIXErrorDomain && [EPERM, EACCES].contains(Int32(failure.code)))
                        || (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError)
                    guard denied, let path = failure.userInfo[NSFilePathErrorKey] as? String,
                          !confirmed.contains(path),
                          let position = urls.firstIndex(where: { $0.path == path }) else { throw error }
                    confirmed.insert(path)
                    guard let authorized = try authorizeEditedFolder(urls[position]) else { return }
                    urls[position] = authorized
                }
            }
            renderState()
            controlWindow.finishFolderEditing()
            record("已更新工作文件夹，共 \(folderAccess.storedURLs.count) 个")
        } catch { showError("无法保存文件夹", error) }
    }

    private func authorizeEditedFolder(_ requested: URL) throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = requested.deletingLastPathComponent()
        panel.prompt = "确认访问"
        panel.message = "请选中刚填写的文件夹以确认访问：\n\(requested.path)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selected = panel.url else { return nil }
        guard selected.resolvingSymlinksInPath().standardizedFileURL == requested.resolvingSymlinksInPath().standardizedFileURL else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInvalidFileNameError,
                userInfo: [NSLocalizedDescriptionKey: "选中的文件夹与填写的路径不同，请重新编辑或确认：\n\(requested.path)"])
        }
        return selected
    }
    private func startFileIndex() {
        renderState()
        index.start(folders: folderAccess.activeURLs) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    private func renderState() {
        controlWindow.render(ControlWindowState(status: statusText,
            detail: running ? index.status : "后台拖动已暂停",
            folders: folderAccess.storedURLs.map(\.path), running: running,
            debugFrames: showDebugFrames, hideDockWhenClosed: hideDockWhenClosed))
    }
    private func showError(_ title: String, _ error: Error) {
        record("\(title)：\(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = [error.localizedDescription, (error as NSError).userInfo[NSFilePathErrorKey] as? String]
            .compactMap { $0 }.joined(separator: "\n")
        alert.runModal()
    }
    func applicationWillTerminate(_ notification: Notification) { stop() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func requestAccess() {
        let alert = NSAlert()
        alert.messageText = "允许 Recents Drag 使用辅助功能"
        alert.informativeText = "在系统设置的辅助功能列表中添加并开启：\n\(Bundle.main.bundlePath)\n\n若更新后开关已开启但仍提示未授权，请移除旧条目，再添加当前 App。授权后回到原 App，打开 Dock 中原本的“最近使用”。退出 Recents Drag 会撤掉所有交互层；系统保存的授权可在设置中移除。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func refresh() {
        guard running, !interacting, !dragging else { return }
        guard !folderAccess.activeURLs.isEmpty else {
            hideOverlays()
            clearSnapshots()
            let trusted = AXIsProcessTrusted()
            setStatus(trusted ? "先授权可访问的工作文件夹，无需逐个选文件" : "等待辅助功能授权")
            if trusted && !promptedForFolders {
                promptedForFolders = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.running else { return }
                    self.chooseFolders()
                }
            }
            return
        }
        let snapshot = DockProbe.scan(diagnostics: showDebugFrames)
        lastSnapshot = snapshot
        if !snapshot.items.isEmpty { lastExpandedSnapshot = snapshot }
        guard snapshot.trusted else {
            hideOverlays()
            setStatus("等待辅助功能授权")
            return
        }
        let resolved = snapshot.items.compactMap { item -> ResolvedDockItem? in
            let url: URL
            let resolution: FileResolution
            if let direct = item.url { url = direct; resolution = .accessibilityURL }
            else if let candidate = index.resolveUnique(label: item.label) {
                url = candidate; resolution = .authorizedFolder
            } else { return nil }
            guard index.contains(url), folderAccess.contains(url),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ResolvedDockItem(element: item.element, label: item.label, url: url,
                                    frame: item.frame, actions: item.actions,
                                    resolution: resolution)
        }
        // AX reports rotated thumbnails as overlapping bounding squares. Use
        // their centers as drag handles rather than rejecting the thumbnails.
        let items = resolved
        let signature = items.map { "\($0.url)|\(NSStringFromRect($0.frame))|\($0.resolution)" }.joined(separator: "\n")
        if signature != currentSignature {
            hideOverlays()
            currentSignature = signature
            overlays = items.map { DragOverlayPanel(item: $0, showDebugFrame: showDebugFrames, controller: self) }
            if !items.isEmpty { record("安装 \(items.count) 个图标中心拖动区") }
        }
        if !items.isEmpty { setStatus("已接管 \(items.count) 个条目，拖出复制") }
        else if !snapshot.items.isEmpty { setStatus("尚未匹配：\(index.status)") }
        else { setStatus(snapshot.summary) }
    }

    private func setStatus(_ text: String) {
        statusText = text
        renderState()
    }

    func interactionStarted(item: ResolvedDockItem) {
        // Clicking another process' window can close Dock's popup before this
        // callback. Keep this already-mapped source alive for the drag gesture.
        record("鼠标按下：\(item.label)")
        interacting = true
    }
    func interactionEnded() { interacting = false; hideOverlays() }
    func record(_ message: String) {
        guard showDebugFrames else { return }
        log.append(message)
        log = Array(log.suffix(12))
    }
    func dragStarted(item: ResolvedDockItem) {
        dragging = true
        record("开始拖动：\(item.url.path)（\(item.resolution.rawValue)）")
    }
    func dragSessionCreated() { overlays.forEach { $0.orderOut(nil) } }
    func dragEnded(operation: NSDragOperation) {
        record(operation.isEmpty ? "拖动取消或目标未接受" : "拖动完成：\(operation.rawValue)")
        dragging = false
        interacting = false
        hideOverlays()
    }
    func hideOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        if !dragging { overlays.removeAll() }
        currentSignature = ""
    }

    @objc private func saveDiagnostics() {
        guard let snapshot = lastExpandedSnapshot ?? lastSnapshot else { return }
        hideOverlays()
        interacting = true
        defer { interacting = false; refresh() }
        let report = DemoDiagnosticReport(snapshot: snapshot, index: index, folderAccess: folderAccess,
                                          running: running, debugFrames: showDebugFrames, log: log)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RecentsDragDemo-diagnostics.json"
        panel.message = "包含最近文件名称、路径及授权目录，仅保存到你选择的位置。"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { showError("诊断保存失败", error) }
        }
    }
    private func clearSnapshots() {
        lastSnapshot = nil
        lastExpandedSnapshot = nil
        log.removeAll()
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--diagnose") {
    let data = MainActor.assumeIsolated { try! JSONEncoder().encode(DockProbe.scan(diagnostics: true).report) }
    FileHandle.standardOutput.write(data)
    print("")
} else if arguments.contains("--stop") {
    MainActor.assumeIsolated {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.caojd.RecentsDragDemo").forEach { _ = $0.terminate() }
    }
} else if arguments.contains("--self-test") {
    let rect = appKitFrame(fromAX: CGRect(x: -500, y: -300, width: 100, height: 70), primaryHeight: 900)
    precondition(rect == CGRect(x: -500, y: 1130, width: 100, height: 70))
    print("PASS: AX → AppKit multi-display coordinates")
} else if arguments.contains("--index-diagnose") {
    let index = RecentFileIndex()
    let folderAccess = FolderAccessStore()
    try folderAccess.restoreAndStart()
    print(folderAccess.status)
    index.start(folders: folderAccess.activeURLs, onUpdate: {})
    RunLoop.main.run(until: Date().addingTimeInterval(10))
    print(index.status)
    index.stop()
    folderAccess.suspend()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let controller = DemoController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
