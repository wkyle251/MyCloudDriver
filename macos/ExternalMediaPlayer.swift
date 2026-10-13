import AppKit
import Foundation

/// Hands a media file to IINA, an mpv-based player, when the in-app player cannot play it smoothly. The original is
/// opened where it is, read-only: nothing is copied, moved or converted.
enum ExternalMediaPlayer {
    static let iinaBundleIdentifier = "com.colliderli.iina"
    static let usualLocations = [
        URL(fileURLWithPath: "/Applications/IINA.app", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/IINA.app", isDirectory: true),
    ]

    /// The installed IINA, or nil. The system's own registration is trusted only while the app is really there.
    static func iinaURL(lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                        fallbacks: [URL] = usualLocations) -> URL? {
        ([lookup(iinaBundleIdentifier)].compactMap { $0 } + fallbacks).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    static func open(_ file: URL, in application: URL,
                     opener: (URL, URL) -> Bool = { file, application in
                         NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
                         return true
                     }) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return opener(file, application)
    }
}
