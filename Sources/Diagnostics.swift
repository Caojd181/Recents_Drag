import Foundation

struct DemoDiagnosticReport: Encodable {
    let demoVersion: String
    let capturedAt = Date()
    let running: Bool
    let debugFrames: Bool
    let indexStatus: String
    let folderAccessStatus: String
    let rememberedFolders: [String]
    let activeFolders: [String]
    let dock: DockProbeReport
    let fileMatches: [FileMatchDiagnostic]
    let log: [String]

    init(snapshot: DockProbeSnapshot, index: RecentFileIndex, folderAccess: FolderAccessStore,
         running: Bool, debugFrames: Bool, log: [String]) {
        demoVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        self.running = running
        self.debugFrames = debugFrames
        indexStatus = index.status
        folderAccessStatus = folderAccess.status
        rememberedFolders = folderAccess.storedURLs.map(\.path)
        activeFolders = folderAccess.activeURLs.map(\.path)
        dock = snapshot.report
        fileMatches = snapshot.items.map { FileMatchDiagnostic(item: $0, index: index, access: folderAccess) }
        self.log = log
    }
}

struct FileMatchDiagnostic: Encodable {
    let label: String
    let frame: DockDiagnosticRect
    let indexedCandidates: [String]
    let path: String?
    let outcome: String
    let exists: Bool?
    let readable: Bool?

    init(item: DockStackItem, index: RecentFileIndex, access: FolderAccessStore) {
        label = item.label
        frame = DockDiagnosticRect(item.frame)
        let lookup = index.lookup(label: item.label)
        indexedCandidates = lookup.indexedCandidates.map(\.path).sorted()
        let url = item.url ?? lookup.uniqueURL
        path = url?.path
        if let url, index.contains(url), access.contains(url) {
            let found = FileManager.default.fileExists(atPath: url.path)
            let canRead = FileManager.default.isReadableFile(atPath: url.path)
            exists = found
            readable = canRead
            outcome = !found ? "文件不可访问或不存在" : (canRead ? "已匹配" : "文件不可读")
        } else {
            exists = nil
            readable = nil
            if lookup.isGathering { outcome = "正在收集索引" }
            else if let url { outcome = index.contains(url) ? "超出已授权目录" : "不在最新 100 条查询结果中" }
            else { outcome = lookup.candidates.isEmpty ? "未进入最近 100 条候选或未被索引" : "同名候选不唯一" }
        }
    }
}
