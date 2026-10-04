import AppKit
import Observation

/// Where an agent may read and write files. Compositor is sandboxed: it reaches Pictures and Downloads on its own, the
/// project that's open, and any folder the person adds in the MCP Server window, remembered as a security-scoped bookmark.
@MainActor @Observable
final class AgentFiles {
    static let shared = AgentFiles()
    private(set) var folders: [URL] = []
    @ObservationIgnored private var bookmarks: [Data] = []
    private static let storageKey = "mcp.folders"

    private init() {
        for data in UserDefaults.standard.array(forKey: Self.storageKey) as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            folders.append(url)
            bookmarks.append(stale ? (try? url.bookmarkData(options: .withSecurityScope)) ?? data : data)
        }
        save()
    }

    /// The person's own home folder: inside the sandbox, `NSHomeDirectory()` is the app's container instead.
    nonisolated static var home: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }
    nonisolated static var standardFolders: [String] { [home + "/Pictures", home + "/Downloads"] }

    /// An absolute file URL for a path an agent gave, with `~` meaning the person's home folder.
    nonisolated static func url(_ path: String) throws -> URL {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { text = url.path }
        if text == "~" { text = home } else if text.hasPrefix("~/") { text = home + text.dropFirst() }
        guard text.hasPrefix("/") else { throw AgentError("Give an absolute path (or one starting with ~/), not “\(path)”.") }
        return URL(fileURLWithPath: text).standardizedFileURL
    }

    func addFolder(window: NSWindow?) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Allow")
        panel.message = String(localized: "AI agents connected over MCP will be able to read and write files in this folder.")
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url, !folders.contains(url),
              let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        _ = url.startAccessingSecurityScopedResource()
        folders.append(url)
        bookmarks.append(data)
        save()
    }

    func removeFolder(_ url: URL) {
        guard let index = folders.firstIndex(of: url) else { return }
        folders[index].stopAccessingSecurityScopedResource()
        folders.remove(at: index)
        bookmarks.remove(at: index)
        save()
    }

    private func save() { UserDefaults.standard.set(bookmarks, forKey: Self.storageKey) }

    /// Every folder an agent can count on, for error messages and the server's instructions.
    var reachable: [String] { Self.standardFolders + folders.map(\.path) }

    /// A file error put in terms an agent can act on: the sandbox is the usual reason a path fails.
    func explain(_ error: Error, path: String) -> AgentError {
        let ns = error as NSError
        let denied = [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) && ns.domain == NSCocoaErrorDomain
            || (ns.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(ns.code))
            || (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains($0.code) } == true
        if denied {
            return AgentError("Compositor is sandboxed and can’t reach \(path). Use a file under \(reachable.joined(separator: ", ")), or ask the person to add its folder in Compositor > MCP Server….")
        }
        if ns.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) {
            return AgentError("There’s no file at \(path).")
        }
        return AgentError("\(path): \(error.localizedDescription)")
    }

    /// A scratch file for image data an agent sent inline or by URL, so it imports like any other file.
    nonisolated static func temporaryFile(_ data: Data, extension pathExtension: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MCP", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
        try data.write(to: url)
        return url
    }

    /// The file type image data holds, from its first bytes.
    nonisolated static func imageExtension(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if bytes.count >= 12, bytes[4...7].elementsEqual("ftyp".utf8) { return "heic" }
        if let text = String(data: data.prefix(512), encoding: .utf8), text.contains("<svg") { return "svg" }
        return nil
    }
}
