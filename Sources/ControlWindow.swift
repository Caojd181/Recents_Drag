import AppKit

enum ControlAction {
    case toggleRunning
    case chooseFolders
    case replaceFolders([String])
    case forgetFolders
    case debugFrames(Bool)
    case hideDockWhenClosed(Bool)
    case requestAccess
    case exportDiagnostics
    case quit
    case windowClosed
}

struct ControlWindowState: Equatable {
    let status: String
    let detail: String
    let folders: [String]
    let running: Bool
    let debugFrames: Bool
    let hideDockWhenClosed: Bool
}

@MainActor
final class ControlWindowController: NSWindowController, NSWindowDelegate {
    private let onAction: (ControlAction) -> Void
    private var lastState: ControlWindowState?
    private var editingFolders = false
    private let statusLabel = NSTextField(labelWithString: "准备中")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let folderCountLabel = NSTextField(labelWithString: "工作文件夹")
    private let folderPaths = NSTextView()
    private let chooseButton = NSButton(title: "添加文件夹…", target: nil, action: nil)
    private let editButton = NSButton(title: "编辑", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let forgetButton = NSButton(title: "忘记", target: nil, action: nil)
    private let runButton = NSButton(title: "暂停", target: nil, action: nil)
    private let debugCheckbox = NSButton(checkboxWithTitle: "显示蓝色拖动框（调试）", target: nil, action: nil)
    private let hideDockCheckbox = NSButton(checkboxWithTitle: "关闭窗口后隐藏 Dock 图标", target: nil, action: nil)

    init(icon: NSImage?, onAction: @escaping (ControlAction) -> Void) {
        self.onAction = onAction
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 570),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Recents Drag"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let iconView = NSImageView()
        iconView.image = icon ?? NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "最近使用")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Recents Drag")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "原生最近文件 · 拖出复制")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let heading = stack([title, subtitle], orientation: .vertical, spacing: 5)
        heading.alignment = .leading
        let header = stack([iconView, heading], spacing: 14)
        header.alignment = .centerY

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        folderCountLabel.font = .systemFont(ofSize: 12, weight: .medium)
        configure(chooseButton, action: #selector(chooseFolders))
        configure(editButton, action: #selector(editOrSaveFolders))
        configure(cancelButton, action: #selector(cancelFolderEditing))
        configure(forgetButton, action: #selector(forgetFolders))
        for control in [chooseButton, editButton, cancelButton, forgetButton] {
            control.controlSize = .small
            control.bezelStyle = .rounded
        }
        cancelButton.isHidden = true
        let folderToolbar = stack([folderCountLabel, NSView(), chooseButton, editButton, cancelButton, forgetButton], spacing: 8)

        folderPaths.isEditable = false
        folderPaths.isSelectable = true
        folderPaths.isRichText = false
        folderPaths.allowsUndo = true
        folderPaths.isAutomaticQuoteSubstitutionEnabled = false
        folderPaths.isAutomaticDashSubstitutionEnabled = false
        folderPaths.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        folderPaths.textContainerInset = NSSize(width: 8, height: 6)
        folderPaths.textContainer?.lineFragmentPadding = 0
        folderPaths.isHorizontallyResizable = false
        folderPaths.isVerticallyResizable = true
        folderPaths.autoresizingMask = [.width]
        folderPaths.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = folderPaths

        configure(debugCheckbox, action: #selector(debugChanged))
        debugCheckbox.state = .off
        configure(hideDockCheckbox, action: #selector(hideDockChanged))
        hideDockCheckbox.state = .on
        let helper = NSTextField(wrappingLabelWithString:
            "关闭窗口后仍在后台运行；再次打开 App 可找回这个窗口。")
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        helper.maximumNumberOfLines = 2
        let separator = NSBox()
        separator.boxType = .separator
        let permissions = button("辅助功能权限…", action: #selector(requestAccess))
        let diagnostics = button("导出诊断…", action: #selector(exportDiagnostics))
        let tools = stack([permissions, diagnostics], spacing: 8)
        tools.distribution = .fillEqually
        configure(runButton, action: #selector(toggleRunning))
        runButton.keyEquivalent = "\r"
        let quitButton = button("完全退出", action: #selector(quit))
        let actions = stack([runButton, NSView(), quitButton], spacing: 8)

        let sections: [NSView] = [header, statusLabel, detailLabel, folderToolbar, scroll,
            debugCheckbox, hideDockCheckbox, helper, separator, tools, actions]
        let content = stack(sections, orientation: .vertical, spacing: 9)
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        guard let parent = window.contentView else { return }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: parent.topAnchor, constant: 18),
            content.bottomAnchor.constraint(lessThanOrEqualTo: parent.bottomAnchor, constant: -18),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            header.heightAnchor.constraint(equalToConstant: 64),
            statusLabel.heightAnchor.constraint(equalToConstant: 18),
            detailLabel.heightAnchor.constraint(equalToConstant: 30),
            folderToolbar.heightAnchor.constraint(equalToConstant: 24),
            scroll.heightAnchor.constraint(equalToConstant: 70),
            debugCheckbox.heightAnchor.constraint(equalToConstant: 18),
            hideDockCheckbox.heightAnchor.constraint(equalToConstant: 18),
            helper.heightAnchor.constraint(equalToConstant: 28),
            separator.heightAnchor.constraint(equalToConstant: 1),
            tools.heightAnchor.constraint(equalToConstant: 26),
            actions.heightAnchor.constraint(equalToConstant: 30),
            runButton.widthAnchor.constraint(equalToConstant: 128),
            quitButton.widthAnchor.constraint(equalToConstant: 104)
        ] + sections.map { $0.widthAnchor.constraint(equalTo: content.widthAnchor) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ state: ControlWindowState) {
        guard state != lastState else { return }
        lastState = state
        statusLabel.stringValue = state.status
        statusLabel.toolTip = state.status
        detailLabel.stringValue = state.detail
        detailLabel.toolTip = state.detail
        updateFolderSection()
        runButton.title = state.running ? "暂停" : "继续运行"
        debugCheckbox.state = state.debugFrames ? .on : .off
        hideDockCheckbox.state = state.hideDockWhenClosed ? .on : .off
    }

    /// The owner calls this only after a successful save; failures keep the draft.
    func finishFolderEditing() {
        editingFolders = false
        folderPaths.undoManager?.removeAllActions()
        updateFolderSection()
    }

    private func updateFolderSection() {
        let folders = lastState?.folders ?? []
        folderCountLabel.stringValue = "工作文件夹（\(folders.count)）"
        chooseButton.isEnabled = !editingFolders
        forgetButton.isEnabled = !editingFolders && !folders.isEmpty
        editButton.title = editingFolders ? "保存" : "编辑"
        cancelButton.isHidden = !editingFolders
        folderPaths.isEditable = editingFolders
        runButton.keyEquivalent = editingFolders ? "" : "\r"
        guard !editingFolders else { return }
        let paths = folders.isEmpty ? "添加存放工作文件的文件夹，无需逐个选择文件。"
            : folders.joined(separator: "\n")
        if folderPaths.string != paths { folderPaths.string = paths }
        folderPaths.textColor = folders.isEmpty ? .secondaryLabelColor : .labelColor
    }

    func windowWillClose(_ notification: Notification) { onAction(.windowClosed) }

    private func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .horizontal,
                       spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = orientation
        result.spacing = spacing
        return result
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
    }

    @objc private func toggleRunning() { onAction(.toggleRunning) }
    @objc private func chooseFolders() { onAction(.chooseFolders) }
    @objc private func editOrSaveFolders() {
        if editingFolders {
            let paths = folderPaths.string.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            onAction(.replaceFolders(paths))
        } else {
            editingFolders = true
            folderPaths.string = (lastState?.folders ?? []).joined(separator: "\n")
            folderPaths.textColor = .labelColor
            folderPaths.undoManager?.removeAllActions()
            updateFolderSection()
            window?.makeFirstResponder(folderPaths)
            folderPaths.setSelectedRange(NSRange(location: folderPaths.string.utf16.count, length: 0))
        }
    }
    @objc private func cancelFolderEditing() { finishFolderEditing() }
    @objc private func forgetFolders() { onAction(.forgetFolders) }
    @objc private func debugChanged(_ sender: NSButton) { onAction(.debugFrames(sender.state == .on)) }
    @objc private func hideDockChanged(_ sender: NSButton) { onAction(.hideDockWhenClosed(sender.state == .on)) }
    @objc private func requestAccess() { onAction(.requestAccess) }
    @objc private func exportDiagnostics() { onAction(.exportDiagnostics) }
    @objc private func quit() { onAction(.quit) }
}
