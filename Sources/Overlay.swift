import AppKit
import ApplicationServices

/// AX uses a top-left origin on the primary display; AppKit uses its bottom-left.
/// Do not use the union of all displays: monitors may be above or left of primary.
func appKitFrame(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
           width: rect.width, height: rect.height)
}

enum FileResolution: String {
    case accessibilityURL = "AX URL"
    case authorizedFolder = "已授权文件夹中的唯一同名文件"
}

struct ResolvedDockItem {
    let element: AXUIElement
    let label: String
    let url: URL
    let frame: CGRect
    let actions: [String]
    let resolution: FileResolution
}

final class DragOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(item: ResolvedDockItem, showDebugFrame: Bool, controller: DemoController) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let fullFrame = appKitFrame(fromAX: item.frame, primaryHeight: primaryHeight)
        let side = min(48, fullFrame.width, fullFrame.height)
        let frame = NSRect(x: fullFrame.midX - side / 2, y: fullFrame.midY - side / 2,
                           width: side, height: side)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // Native Dock stacks are above normal windows. Limit this level to the
        // individual file rectangles, never an invisible full-screen window.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .ignoresCycle]
        animationBehavior = .none
        ignoresMouseEvents = false
        contentView = DragSourceView(item: item, showDebugFrame: showDebugFrame, controller: controller)
        orderFrontRegardless()
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    let item: ResolvedDockItem
    let showDebugFrame: Bool
    weak var controller: DemoController?
    private var downEvent: NSEvent?
    private var downPoint = NSPoint.zero
    private var didStartDrag = false

    init(item: ResolvedDockItem, showDebugFrame: Bool, controller: DemoController) {
        self.item = item
        self.showDebugFrame = showDebugFrame
        self.controller = controller
        super.init(frame: .zero)
        toolTip = "拖出以复制：\(item.url.path)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // A tiny nonzero fill keeps the otherwise clear panel hit-testable.
        NSColor.black.withAlphaComponent(0.002).setFill()
        bounds.fill()
        if showDebugFrame {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            outline.fill()
            NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        controller?.interactionStarted(item: item)
        downEvent = event
        downPoint = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let original = downEvent else { return }
        let point = event.locationInWindow
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4 else { return }
        guard FileManager.default.isReadableFile(atPath: item.url.path) else {
            controller?.record("拖动未启动：文件不可读：\(item.url.path)")
            downEvent = nil
            controller?.interactionEnded()
            return
        }
        didStartDrag = true
        let dragged = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: 64, height: 64)
        let local = convert(original.locationInWindow, from: nil)
        dragged.setDraggingFrame(NSRect(x: local.x - 32, y: local.y - 32, width: 64, height: 64), contents: icon)
        controller?.dragStarted(item: item)
        // AppKit requires the original mouse-down event, not mouseDragged.
        // Keep this view and its window alive until the session ends.
        let session = beginDraggingSession(with: [dragged], event: original, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard downEvent != nil, !didStartDrag else { return }
        defer {
            downEvent = nil
            controller?.interactionEnded()
        }
        controller?.hideOverlays()
        if event.modifierFlags.contains(.command) {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
            return
        }
        // Prefer the original Dock action. Only use openURL when the original
        // AX element is no longer valid after the overlay click.
        let result = item.actions.contains(kAXPressAction as String)
            ? AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            : .actionUnsupported
        if result != .success {
            controller?.record("原生点击不可用，直接打开已确认文件：\(item.label)")
            NSWorkspace.shared.open(item.url)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.interactionStarted(item: item)
        controller?.hideOverlays()
        if item.actions.contains(kAXShowMenuAction as String) {
            let error = AXUIElementPerformAction(item.element, kAXShowMenuAction as CFString)
            controller?.record("原生菜单动作：\(error.rawValue)")
        } else {
            controller?.record("此条目没有公开 AXShowMenu；Demo 未模拟右键菜单。")
        }
        controller?.interactionEnded()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Source never offers a move or removes originals.
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        controller?.record("系统拖动会话已开始")
        controller?.dragSessionCreated()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        downEvent = nil
        controller?.dragEnded(operation: operation)
    }
}
