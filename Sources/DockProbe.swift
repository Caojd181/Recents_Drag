import AppKit
import ApplicationServices

// Accessibility coordinates use the main display's top-left origin.
struct DockDiagnosticRect: Codable {
    let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }
}

struct DockStackItem {
    let element: AXUIElement
    let label: String
    let url: URL?
    let frame: CGRect
    let actions: [String]
}

struct DockNodeDiagnostic: Codable {
    let id: Int, parentID: Int?, depth: Int
    let role: String, subrole: String, label: String
    let frame: DockDiagnosticRect?
    let rawURL: String?, directURL: String?, urlAttribute: String?
    let actions: [String], attributes: [String]
    var qualification: String
}

struct DockProbeReport: Codable {
    let trusted: Bool
    let dockPID: pid_t?
    let summary: String
    let truncated: Bool
    let nodes: [DockNodeDiagnostic]
}

struct DockProbeSnapshot {
    let trusted: Bool
    let dockPID: pid_t?
    let summary: String
    let items: [DockStackItem]
    let nodes: [DockNodeDiagnostic]
    let truncated: Bool

    var report: DockProbeReport {
        DockProbeReport(trusted: trusted, dockPID: dockPID, summary: summary,
                        truncated: truncated, nodes: nodes)
    }
}

@MainActor
enum DockProbe {
    static func scan(diagnostics: Bool = false) -> DockProbeSnapshot {
        let trusted = AXIsProcessTrusted()
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        guard trusted, let pid else {
            return empty(trusted: trusted, pid: pid,
                         summary: trusted ? "没有找到 Dock 进程" : "等待辅助功能授权")
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let list = children(app).first(where: { value($0, "AXRole") as? String == "AXList" }),
              let dockBar = frame(list), dockBar.width > 0, dockBar.height > 0 else {
            return empty(trusted: true, pid: pid, summary: "没有读到原生 Dock 列表")
        }
        let recents = children(list).first { element in
            let title = value(element, "AXTitle") as? String ?? ""
            return isRecentsLabel(title) && value(element, "AXRole") as? String == "AXDockItem"
        }
        guard let recents else {
            return empty(trusted: true, pid: pid, summary: "没有找到 Dock 中的“最近使用”入口")
        }

        var reportNodes: [DockNodeDiagnostic] = []
        if diagnostics {
            reportNodes.append(describe(app, id: 0, parent: nil, depth: 0))
            reportNodes.append(describe(list, id: 1, parent: 0, depth: 1))
        }
        var queue: [(element: AXUIElement, parent: Int, depth: Int)] = [(recents, 1, 2)]
        var visited: [AXUIElement] = []
        var items: [DockStackItem] = []
        var cursor = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        let bar = dockBar.insetBy(dx: -3, dy: -3)
        let itemRoles: Set<String> = ["AXDockItem", "AXIcon", "AXButton", "AXImage", "AXCell", "AXRow", "AXLink", "AXMenuItem", "AXStaticText"]

        // Only this confirmed Recents subtree can provide drag handles. Other
        // Dock apps are inspected for their titles only, never their URL/actions.
        while cursor < queue.count, items.count < RecentFileIndex.limit,
              visited.count < 500, ProcessInfo.processInfo.systemUptime < deadline {
            let pending = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, pending.element) }) { continue }
            let element = pending.element
            visited.append(element)
            let id = diagnostics ? reportNodes.count : visited.count + 1
            let role = value(element, "AXRole") as? String ?? ""
            let isItemRole = itemRoles.contains(role)
            var label = isItemRole || diagnostics ? Self.label(element) : ""
            let rect = isItemRole || diagnostics ? frame(element) : nil
            let descendants = children(element, limit: RecentFileIndex.limit + 1)
            let positioned = rect.map {
                isItemRole && $0.width > 0 && $0.height > 0
                    && !bar.contains(CGPoint(x: $0.midX, y: $0.midY))
            } ?? false
            let attributes = diagnostics ? names(element, actions: false) : nil
            let file = positioned || diagnostics ? fileURL(element, attributes: attributes) : (nil, nil, nil)
            if label.isEmpty, let url = file.0 { label = url.lastPathComponent }
            let validLabel = !label.isEmpty && !isRecentsLabel(label)
                && !label.hasPrefix("“访达”中还有")
                && !["在访达中打开", "在“访达”中打开", "open in finder", "show in finder"].contains(label.lowercased())
            let qualified = positioned && validLabel && (file.0 != nil || descendants.isEmpty)
            let actions = qualified || diagnostics ? names(element, actions: true) : []
            if qualified, let rect {
                items.append(DockStackItem(element: element, label: label, url: file.0,
                    frame: rect, actions: actions))
            }
            if diagnostics {
                reportNodes.append(DockNodeDiagnostic(id: id, parentID: pending.parent, depth: pending.depth,
                    role: role, subrole: value(element, "AXSubrole") as? String ?? "", label: label,
                    frame: rect.map(DockDiagnosticRect.init), rawURL: file.1,
                    directURL: file.0?.absoluteString, urlAttribute: file.2,
                    actions: actions, attributes: attributes ?? [],
                    qualification: qualified ? "recents-item" : "not-a-stack-item"))
            }
            if pending.depth < 16 {
                queue.append(contentsOf: descendants.map { ($0, id, pending.depth + 1) })
            }
        }
        let summary = items.isEmpty ? "尚未读到展开的最近使用条目"
            : "确认 \(items.count) 个条目，\(items.filter { $0.url != nil }.count) 个直接提供文件地址"
        return DockProbeSnapshot(trusted: true, dockPID: pid, summary: summary,
            items: items, nodes: reportNodes,
            truncated: cursor < queue.count)
    }

    private static func empty(trusted: Bool, pid: pid_t?, summary: String) -> DockProbeSnapshot {
        DockProbeSnapshot(trusted: trusted, dockPID: pid, summary: summary,
                          items: [], nodes: [], truncated: false)
    }

    private static func describe(_ element: AXUIElement, id: Int, parent: Int?, depth: Int) -> DockNodeDiagnostic {
        let attributes = names(element, actions: false)
        let file = fileURL(element, attributes: attributes)
        return DockNodeDiagnostic(id: id, parentID: parent, depth: depth,
            role: value(element, "AXRole") as? String ?? "",
            subrole: value(element, "AXSubrole") as? String ?? "", label: label(element),
            frame: frame(element).map(DockDiagnosticRect.init), rawURL: file.1,
            directURL: file.0?.absoluteString, urlAttribute: file.2,
            actions: names(element, actions: true), attributes: attributes,
            qualification: "not-a-stack-item")
    }

    private static func isRecentsLabel(_ label: String) -> Bool {
        ["最近使用", "recents"].contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func label(_ element: AXUIElement) -> String {
        for attribute in ["AXTitle", "AXDescription", "AXValue"] {
            if let text = value(element, attribute) as? String, !text.isEmpty { return text }
        }
        return ""
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func names(_ element: AXUIElement, actions: Bool) -> [String] {
        var result: CFArray?
        let error = actions ? AXUIElementCopyActionNames(element, &result) : AXUIElementCopyAttributeNames(element, &result)
        return error == .success ? result as? [String] ?? [] : []
    }

    private static func children(_ element: AXUIElement, limit: Int = 500) -> [AXUIElement] {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, "AXChildren" as CFString, &count) == .success,
              count > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, min(count, limit), &values) == .success else { return [] }
        let result = values as? [AXUIElement] ?? []
        for child in result { AXUIElementSetMessagingTimeout(child, 0.05) }
        return result
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, "AXPosition"), let size = value(element, "AXSize"),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let pointValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func fileURL(_ element: AXUIElement, attributes: [String]?)
        -> (URL?, String?, String?) {
        var firstRaw: (URL?, String?, String?) = (nil, nil, nil)
        for attribute in ["AXURL", "AXDocument", "AXFilename", "AXFileURL", "AXPath"] {
            if let attributes, !attributes.contains(attribute) { continue }
            guard let result = value(element, attribute) else { continue }
            let raw = (result as? URL)?.absoluteString ?? result as? String
            guard let raw else { continue }
            if firstRaw.1 == nil { firstRaw = (nil, raw, attribute) }
            let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL(string: raw)
            if let url, url.isFileURL { return (url, raw, attribute) }
        }
        return firstRaw
    }
}
