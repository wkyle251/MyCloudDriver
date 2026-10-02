import Foundation
import UniformTypeIdentifiers

enum BrowserFileCategory: String, CaseIterable, Hashable {
    case images, videos, audio, documents, archives, other

    var title: String {
        switch self {
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .other: return "Other Files"
        }
    }
}

/// A presentation filter over files: folders always stay visible so the tree
/// they hold can still be browsed. Original listings, paging tokens and folder
/// caches stay intact, and filtering never fetches or scans unopened folders.
enum BrowserFileFilter: Hashable {
    case all
    case category(BrowserFileCategory)
    case fileExtension(String)

    var isActive: Bool { self != .all }
    var title: String {
        switch self {
        case .all: return "All Types"
        case .category(let category): return category.title
        case .fileExtension(let value): return value.isEmpty ? "No Extension" : ".\(value)"
        }
    }

    func matches(_ item: BrowserItem) -> Bool {
        matches(isFolder: item.isFolder, extension: item.normalizedFileExtension, mimeType: item.mimeType)
    }

    func matches(_ item: CloudDriveItem) -> Bool {
        matches(isFolder: item.isFolder, extension: Self.extensionOf(item.name), mediaType: item.mediaType)
    }

    static func extensionOf(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    private func matches(isFolder: Bool, extension ext: String, mimeType: String? = nil, mediaType: String? = nil) -> Bool {
        guard isActive else { return true }
        // A filter narrows files, not navigation: every folder stays in place
        // so its matching contents keep an ancestry the user can open.
        guard !isFolder else { return true }
        switch self {
        case .all: return true
        case .fileExtension(let value): return ext == value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        case .category(let expected): return Self.category(extension: ext, mimeType: mimeType, mediaType: mediaType) == expected
        }
    }

    private static func category(extension ext: String, mimeType: String?, mediaType: String?) -> BrowserFileCategory {
        let mime = (mimeType ?? "").split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // Provider metadata also identifies extensionless Photos assets and
        // disambiguates text files such as TypeScript from transport streams.
        if mime.hasPrefix("image/") || mediaType == "image" { return .images }
        if mime.hasPrefix("video/") || mediaType == "video" { return .videos }
        if mime.hasPrefix("audio/") || mediaType == "audio" { return .audio }
        if mime.hasPrefix("text/") { return .documents }

        if imageExtensions.contains(ext) { return .images }
        if videoExtensions.contains(ext) { return .videos }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) || documentMIMETypes.contains(mime) { return .documents }
        if archiveExtensions.contains(ext) || archiveMIMETypes.contains(mime) { return .archives }

        let type = (!mime.isEmpty && mime != "application/octet-stream" ? UTType(mimeType: mime) : nil)
            ?? UTType(filenameExtension: ext)
        if let type {
            if type.conforms(to: .image) { return .images }
            if type.conforms(to: .movie) { return .videos }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .text) || type.conforms(to: .pdf)
                || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation)
                || type.conforms(to: .compositeContent) { return .documents }
            if type.conforms(to: .archive) { return .archives }
        }
        return .other
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "svg", "ico", "raw", "dng", "cr2", "cr3", "nef", "arw"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "m2ts", "mts", "wmv", "flv", "3gp"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "ogg", "opus", "wma", "alac", "mid", "midi"]
    private static let documentExtensions: Set<String> = ["pdf", "txt", "text", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt", "pages", "xls", "xlsx", "ods", "numbers", "csv", "tsv", "ppt", "pptx", "odp", "key", "epub", "mobi", "json", "xml", "yaml", "yml", "log", "srt", "vtt"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "gzip", "bz2", "xz", "tgz", "tbz", "tbz2", "txz", "zst", "lz", "lzma", "cab", "iso", "dmg"]
    private static let documentMIMETypes: Set<String> = ["application/pdf", "application/epub+zip", "application/json", "application/xml", "application/rtf", "application/msword", "application/vnd.ms-excel", "application/vnd.ms-powerpoint"]
    private static let archiveMIMETypes: Set<String> = ["application/zip", "application/x-zip-compressed", "application/vnd.rar", "application/x-rar", "application/x-rar-compressed", "application/x-7z-compressed", "application/x-tar", "application/gzip", "application/x-gzip", "application/x-bzip2", "application/x-xz"]
}
