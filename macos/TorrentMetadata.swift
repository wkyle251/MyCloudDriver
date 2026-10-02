import Foundation

/// Just enough bencode to read flags out of a `.torrent` file.
///
/// aria2 owns torrent parsing; the app only needs the `private` flag, because a
/// private torrent must never be announced to a tracker its metadata does not
/// name. Reading it here keeps fallback trackers off those torrents.
enum TorrentMetadata {
    enum PrivateFlag: Equatable {
        case `private`
        case shareable
        /// The file could not be parsed, so the flag is unknown.
        case unreadable
    }

    /// Unreadable metadata is reported as such; callers withhold trackers for it
    /// rather than guess that a torrent is shareable.
    static func privacy(_ data: Data) -> PrivateFlag {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.take(.dictionary) else { return .unreadable }
        while let more = reader.moreInContainer(), more {
            guard let key = reader.string() else { return .unreadable }
            guard key == Array("info".utf8) else {
                guard reader.skip() else { return .unreadable }
                continue
            }
            guard reader.take(.dictionary) else { return .unreadable }
            while let deeper = reader.moreInContainer(), deeper {
                guard let inner = reader.string() else { return .unreadable }
                guard inner == Array("private".utf8) else {
                    guard reader.skip() else { return .unreadable }
                    continue
                }
                guard let flag = reader.integer() else { return .unreadable }
                return flag == 1 ? .private : .shareable
            }
            return .shareable
        }
        return .unreadable
    }

    private struct Reader {
        enum Marker: UInt8 { case dictionary = 0x64, list = 0x6C, integer = 0x69, end = 0x65 }

        let bytes: [UInt8]
        var index = 0

        mutating func take(_ marker: Marker) -> Bool {
            guard index < bytes.count, bytes[index] == marker.rawValue else { return false }
            index += 1
            return true
        }

        /// True while the container has more entries, false at its terminator
        /// (which is consumed), nil when the data ran out first.
        mutating func moreInContainer() -> Bool? {
            guard index < bytes.count else { return nil }
            return take(.end) ? false : true
        }

        mutating func string() -> [UInt8]? {
            let start = index
            var length = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                let (scaled, overflow) = length.multipliedReportingOverflow(by: 10)
                guard !overflow else { return nil }
                length = scaled + Int(bytes[index] - 0x30)
                guard length <= bytes.count else { return nil }
                index += 1
            }
            guard index > start, index < bytes.count, bytes[index] == 0x3A else { return nil }
            index += 1
            guard index + length <= bytes.count else { return nil }
            defer { index += length }
            return Array(bytes[index..<index + length])
        }

        mutating func integer() -> Int? {
            guard take(.integer) else { return nil }
            let start = index
            if index < bytes.count, bytes[index] == 0x2D { index += 1 }
            var digits = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1; digits += 1 }
            guard digits > 0, index < bytes.count, bytes[index] == Marker.end.rawValue else { return nil }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return Int(text)
        }

        /// Steps over one value of any type. A dictionary is a flat run of
        /// key/value pairs, so alternating skips cover both.
        mutating func skip(depth: Int = 0) -> Bool {
            guard depth < 64, index < bytes.count else { return false }
            switch bytes[index] {
            case Marker.integer.rawValue:
                return integer() != nil
            case Marker.list.rawValue, Marker.dictionary.rawValue:
                index += 1
                while let more = moreInContainer() {
                    if !more { return true }
                    guard skip(depth: depth + 1) else { return false }
                }
                return false
            default:
                return string() != nil
            }
        }
    }
}
