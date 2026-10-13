import Foundation

/// A type filter leaves folders in place so their contents can be opened. Once a folder's contents are known, and
/// nothing in it or below it matches, that folder is only clutter. This decides which ones, for every browser.
///
/// Filtering never fetches or scans: a folder that was never opened, is still loading, failed to load, or has more
/// pages to come might hold a match, so it always stays.
enum BrowserEmptyFolders {
    static let preferenceKey = "browserHidesEmptyFolders"

    /// On until the user turns it off. The same choice applies to PikPak and to every other drive.
    static func preference(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func setPreference(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: preferenceKey)
    }

    /// The ids among `folderIDs` that are known to hold nothing the filter shows. `children` returns a folder's
    /// complete listing, or nil when it is not known; a folder with an unknown subfolder is itself unknown.
    static func emptyFolderIDs<Item, IDs: Sequence>(among folderIDs: IDs, children: (String) -> [Item]?,
                                                    id: (Item) -> String, isFolder: (Item) -> Bool,
                                                    matches: (Item) -> Bool) -> Set<String> where IDs.Element == String {
        var hasContent: [String: Bool] = [:]
        var visiting = Set<String>()
        func content(of folder: String) -> Bool {
            if let known = hasContent[folder] { return known }
            guard let listing = children(folder) else { hasContent[folder] = true; return true }
            // A folder that leads back to itself cannot be judged by its own contents, so it is never hidden.
            guard visiting.insert(folder).inserted else { return true }
            defer { visiting.remove(folder) }
            let found = listing.contains { isFolder($0) ? content(of: id($0)) : matches($0) }
            hasContent[folder] = found
            return found
        }
        var empty = Set<String>()
        for folder in folderIDs where !content(of: folder) { empty.insert(folder) }
        return empty
    }
}
