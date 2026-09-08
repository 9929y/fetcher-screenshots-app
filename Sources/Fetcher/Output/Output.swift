import AppKit
import UniformTypeIdentifiers

/// Where a finished capture goes.
///
/// The three target tools split into two families, which is why there are two
/// primary clipboard paths rather than one:
///
/// - **Cursor** takes a pasted image directly, so PNG-on-clipboard wins.
/// - **Claude Code** and **Codex** are terminal-first, where the reliable
///   currency is a *file path* — paste it and reference the file. So the
///   capture is always written to disk, and copying the path is a first-class
///   action, not an afterthought.
///
/// Writing the file unconditionally also means the drag-out source always has
/// a real file behind it, which is the compatible path for every drop target.
enum Output {

    static let folderName = "Fetcher"

    // MARK: Encoding

    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Disk

    static var defaultSaveDirectory: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    static var saveDirectory: URL { Settings.shared.saveDirectory }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    @discardableResult
    static func write(_ image: CGImage, date: Date = Date()) throws -> URL {
        let dir = saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Fetcher \(stamp.string(from: date)).png")
        guard let data = pngData(image) else {
            throw NSError(domain: "Fetcher", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode the capture as PNG."
            ])
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Clipboard

    /// PNG on the clipboard. For Cursor, and for anything that accepts a paste.
    static func copyImage(_ image: CGImage) {
        guard let data = pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }

    /// A POSIX path as plain text, plus the file URL flavor so the same
    /// clipboard also works for a paste into Finder or a file field.
    /// For Claude Code and Codex.
    static func copyPath(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.path, forType: .string)
        item.setString(url.absoluteString, forType: .fileURL)
        pb.writeObjects([item])
    }
}
