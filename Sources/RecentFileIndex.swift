import Foundation
import CoreFoundation

struct FileLookup {
    let indexedCandidates: Set<URL>
    let isGathering: Bool
    var candidates: Set<URL> { indexedCandidates }

    init(indexedCandidates: Set<URL>, isGathering: Bool = false) {
        self.indexedCandidates = indexedCandidates
        self.isGathering = isGathering
    }

    var uniqueURL: URL? { !isGathering && candidates.count == 1 ? candidates.first : nil }
}

struct RecentFileEntry {
    let url: URL
    let names: [String]
}

/// Input is already ordered newest first by the metadata query.
struct RecentFileWindow {
    let sortedURLs: [URL]
    let urls: Set<URL>
    let names: [String: Set<URL>]

    init(entries: [RecentFileEntry]) {
        var sorted: [URL] = []
        var members = Set<URL>()
        var aliases: [String: Set<URL>] = [:]
        for entry in entries.prefix(RecentFileIndex.limit) {
            let url = entry.url.standardizedFileURL
            if members.insert(url).inserted { sorted.append(url) }
            for name in entry.names { aliases[name, default: []].insert(url) }
        }
        sortedURLs = sorted
        urls = members
        names = aliases
    }
}

/// Live recent-file metadata from folders authorized by the user.
/// The caller owns folder-access grants; stop() removes this query and observers.
final class RecentFileIndex: NSObject {
    static let limit = 100
    private var query: NSMetadataQuery?
    private var window = RecentFileWindow(entries: [])
    private var callback: (() -> Void)?
    private var ready = false
    private var scopeNote = ""
    private(set) var count = 0
    private(set) var status = "先授权文件夹"
    var sortedURLs: [URL] { window.sortedURLs }

    func start(folders: [URL], onUpdate: @escaping () -> Void) {
        stop()
        callback = onUpdate
        guard !folders.isEmpty else {
            status = "先授权文件夹"
            onUpdate()
            return
        }
        guard let configuration = dockConfiguration(),
              let rawQuery = configuration["RawQuery"] as? String,
              let predicate = NSPredicate(fromMetadataQueryString: rawQuery) else {
            status = "没有读到现有“最近使用”的查询"
            onUpdate()
            return
        }
        scopeNote = "仅检索 \(folders.count) 个已授权文件夹"
        let query = NSMetadataQuery()
        self.query = query
        query.predicate = predicate
        query.searchScopes = folders
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        query.notificationBatchingInterval = 0.5
        NotificationCenter.default.addObserver(self, selector: #selector(gathered),
            name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(updated),
            name: .NSMetadataQueryDidUpdate, object: query)
        status = "正在收集元数据；\(scopeNote)"
        if !query.start() { status = "Spotlight 查询未能启动" }
        onUpdate()
    }

    func stop() {
        if let query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            query.stop()
        }
        query = nil
        callback = nil
        window = RecentFileWindow(entries: [])
        ready = false
        count = 0
        status = "最近文件检索已停止"
    }

    /// No fuzzy matching: zero or multiple exact-name candidates are rejected.
    func resolveUnique(label: String) -> URL? {
        lookup(label: label).uniqueURL
    }

    func contains(_ url: URL) -> Bool {
        window.urls.contains(url.standardizedFileURL)
    }

    func lookup(label: String) -> FileLookup {
        let indexed = ready ? window.names[label] ?? [] : []
        return FileLookup(indexedCandidates: indexed,
                          isGathering: query?.isGathering ?? false)
    }

    @objc private func gathered() {
        ready = true
        rebuild()
    }

    @objc private func updated() {
        if ready { rebuild() }
    }

    private func rebuild() {
        guard let query else { return }
        var entries: [RecentFileEntry] = []
        query.disableUpdates()
        let resultCount = query.resultCount
        // The system query may match more; only its newest 100 are read here.
        for position in 0..<min(Self.limit, resultCount) {
            guard let item = query.result(at: position) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var labels = [url.lastPathComponent, FileManager.default.displayName(atPath: path)]
            for key in ["kMDItemFSName", "kMDItemDisplayName"] {
                if let label = item.value(forAttribute: key) as? String { labels.append(label) }
            }
            entries.append(RecentFileEntry(url: url, names: labels))
        }
        window = RecentFileWindow(entries: entries)
        count = window.sortedURLs.count
        status = "按最近使用定位 \(count) 个文件（最多 \(Self.limit) 个）；\(scopeNote)"
        query.enableUpdates()
        callback?()
    }

    private func dockConfiguration() -> [String: Any]? {
        var items = CFPreferencesCopyAppValue("persistent-others" as CFString,
            "com.apple.dock" as CFString) as? [[String: Any]]
        if items == nil {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                items = plist["persistent-others"] as? [[String: Any]]
            }
        }
        return items?.first {
            let data = $0["tile-data"] as? [String: Any]
            return $0["tile-type"] as? String == "smartfolder-tile"
                && ["最近使用", "Recents"].contains(data?["label"] as? String ?? "")
        }?["tile-data"] as? [String: Any]
    }
}
