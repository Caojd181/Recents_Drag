import Foundation
import Darwin

final class FolderAccessStore {
    private struct Bookmark: Codable {
        let data: Data
        let securityScoped: Bool
    }

    let configurationURL: URL
    private(set) var storedURLs: [URL] = []
    private(set) var activeURLs: [URL] = []
    private(set) var status = "尚未选择文件夹"
    private var startedURLs: [URL] = []

    init(configurationURL: URL? = nil) {
        self.configurationURL = configurationURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecentsDragDemo/folders.plist")
    }

    deinit { suspend() }

    func restoreAndStart() throws {
        suspend()
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            status = "尚未选择文件夹"
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
            ofItemAtPath: configurationURL.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        var bookmarks = try PropertyListDecoder().decode([Bookmark].self,
            from: Data(contentsOf: configurationURL))
        var staleIndexes: [Int] = []
        let urls = try bookmarks.enumerated().map { index, bookmark in
            var stale = false
            var options: URL.BookmarkResolutionOptions = [.withoutUI]
            options.insert(bookmark.securityScoped ? .withSecurityScope : .withoutImplicitStartAccessing)
            let url = try URL(resolvingBookmarkData: bookmark.data, options: options,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { staleIndexes.append(index) }
            return url
        }
        try activate(urls)
        do {
            for index in staleIndexes { bookmarks[index] = try makeBookmark(urls[index]) }
            if !staleIndexes.isEmpty { try save(bookmarks) }
        } catch {
            suspend()
            throw error
        }
        storedURLs = urls
        describe(bookmarks)
    }

    func add(_ urls: [URL]) throws {
        try replace(storedURLs + urls)
    }

    func replace(_ urls: [URL]) throws {
        guard !urls.isEmpty else { try forget(); return }
        var selected: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if let index = selected.firstIndex(where: { $0.standardizedFileURL.path == path }) {
                selected[index] = url
            } else {
                selected.append(url)
            }
        }
        var stagedScopes: [URL] = []
        do {
            // Keep old scopes live until the replacement has committed.
            for url in selected {
                if url.startAccessingSecurityScopedResource() { stagedScopes.append(url) }
                try checkDirectory(url)
            }
            let bookmarks = try selected.map(makeBookmark)
            try save(bookmarks)
            suspend()
            startedURLs = stagedScopes
            activeURLs = selected
            storedURLs = selected
            describe(bookmarks)
        } catch {
            for url in stagedScopes { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func suspend() {
        for url in startedURLs { url.stopAccessingSecurityScopedResource() }
        startedURLs = []
        activeURLs = []
        status = "已停止访问文件夹"
    }

    func forget() throws {
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            try FileManager.default.removeItem(at: configurationURL)
        }
        suspend()
        storedURLs = []
        status = "已清除文件夹记录"
        // rmdir leaves nonempty directories intact.
        _ = rmdir(configurationURL.deletingLastPathComponent().path)
    }

    func contains(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return activeURLs.contains { folder in
            let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path == root || path.hasPrefix(prefix)
        }
    }

    private func activate(_ urls: [URL]) throws {
        suspend()
        do {
            for url in urls {
                if url.startAccessingSecurityScopedResource() { startedURLs.append(url) }
                // A non-sandboxed app can have access without an explicit scope.
                try checkDirectory(url)
            }
            activeURLs = urls
        } catch {
            suspend()
            throw error
        }
    }

    private func checkDirectory(_ url: URL) throws {
        guard let directory = opendir(url.path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        closedir(directory)
    }

    private func makeBookmark(_ url: URL) throws -> Bookmark {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                           includingResourceValuesForKeys: nil, relativeTo: nil)
            return Bookmark(data: data, securityScoped: true)
        } catch {
            // Ordinary bookmarks remember locations; they do not grant new access.
            do {
                let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                return Bookmark(data: data, securityScoped: false)
            } catch {
                let failure = error as NSError
                var info = failure.userInfo
                info[NSFilePathErrorKey] = url.path
                throw NSError(domain: failure.domain, code: failure.code, userInfo: info)
            }
        }
    }

    private func save(_ bookmarks: [Bookmark]) throws {
        let directory = configurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".folders-\(UUID().uuidString).plist")
        defer { _ = unlink(temporary.path) }
        try PropertyListEncoder().encode(bookmarks).write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, configurationURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: configurationURL.path])
        }
    }

    private func describe(_ bookmarks: [Bookmark]) {
        let scoped = bookmarks.filter(\.securityScoped).count
        status = "已启用 \(activeURLs.count) 个文件夹；安全作用域书签 \(scoped)，普通书签 \(bookmarks.count - scoped)"
    }
}
