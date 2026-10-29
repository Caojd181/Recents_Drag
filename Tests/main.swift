import Foundation

let fm = FileManager.default
let fixture = fm.temporaryDirectory.appendingPathComponent("recents-lookup-\(UUID().uuidString)")
let first = fixture.appendingPathComponent("first")
let second = fixture.appendingPathComponent("first-other")
try fm.createDirectory(at: first, withIntermediateDirectories: true)
try fm.createDirectory(at: second, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: fixture) }
let file = first.appendingPathComponent("Report.pdf")
try Data().write(to: file)

let index = RecentFileIndex()
index.start(folders: [first, second], onUpdate: {})
func waitForGathering() {
    let deadline = Date().addingTimeInterval(5)
    while index.lookup(label: "Report.pdf").isGathering, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    precondition(!index.lookup(label: "Report.pdf").isGathering)
}
waitForGathering()
let unindexed = index.lookup(label: "Report.pdf")
precondition(unindexed.indexedCandidates.isEmpty)
precondition(unindexed.uniqueURL == nil)
precondition(!index.contains(file))
precondition(index.resolveUnique(label: "../first/Report.pdf") == nil)
precondition(index.resolveUnique(label: first.path) == nil)
precondition(index.resolveUnique(label: "..") == nil)

try Data().write(to: second.appendingPathComponent("Report.pdf"))
precondition(index.lookup(label: "Report.pdf").candidates.isEmpty)
precondition(index.resolveUnique(label: "Report.pdf") == nil)
try fm.createDirectory(at: first.appendingPathComponent("Folder.pdf"), withIntermediateDirectories: false)
precondition(index.resolveUnique(label: "Folder.pdf") == nil)
index.stop()
precondition(index.resolveUnique(label: "Report.pdf") == nil)
print("PASS: strict indexed-only lookup, directory boundaries, stop")

precondition(FileLookup(indexedCandidates: [file], isGathering: true).uniqueURL == nil)
let ordered = (0...100).map { rank in
    RecentFileEntry(url: first.appendingPathComponent("rank-\(rank).pdf"), names: ["rank-\(rank).pdf"])
}
let latest = RecentFileWindow(entries: ordered)
precondition(latest.sortedURLs == Array(ordered.prefix(100)).map(\.url))
precondition(latest.urls.count == 100 && !latest.urls.contains(ordered[100].url))
precondition(latest.names["rank-100.pdf"] == nil)
let reordered = RecentFileWindow(entries: [ordered[100]] + ordered)
precondition(reordered.sortedURLs.first == ordered[100].url)
precondition(reordered.urls.count == 100 && !reordered.urls.contains(ordered[99].url))
precondition(reordered.names["rank-99.pdf"] == nil)
let collision = RecentFileWindow(entries: [
    RecentFileEntry(url: first.appendingPathComponent("Same.pdf"), names: ["Same.pdf"]),
    RecentFileEntry(url: second.appendingPathComponent("Same.pdf"), names: ["Same.pdf"])
])
precondition(FileLookup(indexedCandidates: collision.names["Same.pdf"]!).uniqueURL == nil)
print("PASS: 101-entry cap, order, eviction, name-map cleanup, ambiguity")
let configuration = fixture.appendingPathComponent("settings/folders.plist")
let access = FolderAccessStore(configurationURL: configuration)
try access.add([first])
precondition(access.contains(file))
precondition(!access.contains(second.appendingPathComponent("Report.pdf")))
let link = first.appendingPathComponent("outside.pdf")
try fm.createSymbolicLink(at: link, withDestinationURL: second.appendingPathComponent("Report.pdf"))
precondition(!access.contains(link))
let mode = try fm.attributesOfItem(atPath: configuration.path)[.posixPermissions] as! NSNumber
precondition(mode.intValue & 0o777 == 0o600)
try access.replace([second, first, second])
precondition(access.storedURLs == [second, first])
let previousConfiguration = try Data(contentsOf: configuration)
do {
    try access.replace([first, file])
    preconditionFailure("A file cannot replace a folder")
} catch {
    precondition((error as NSError).userInfo[NSFilePathErrorKey] as? String == file.path)
}
precondition(access.storedURLs == [second, first])
precondition(access.contains(file) && access.contains(second.appendingPathComponent("Report.pdf")))
let unchangedConfiguration = try Data(contentsOf: configuration)
precondition(unchangedConfiguration == previousConfiguration)
try access.replace([first])
precondition(!access.contains(second.appendingPathComponent("Report.pdf")))
access.suspend()
precondition(!access.contains(file))
try access.restoreAndStart()
precondition(access.contains(file))
try access.replace([])
precondition(!fm.fileExists(atPath: configuration.deletingLastPathComponent().path))
print("PASS: authorization boundary, private permissions, replace, rollback, resume, clear")

if CommandLine.arguments.count > 1 {
    let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    index.start(folders: [target.deletingLastPathComponent()], onUpdate: {})
    waitForGathering()
    let match = index.lookup(label: target.lastPathComponent)
    precondition(match.uniqueURL == target)
    precondition(index.contains(target) && index.count <= RecentFileIndex.limit)
    precondition(fm.isReadableFile(atPath: target.path))
    index.stop()
    print("PASS: supplied file resolves from its authorized directory")
}
