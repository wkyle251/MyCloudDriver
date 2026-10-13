import Foundation
import UniformTypeIdentifiers

/// A video's container, recognized by its first bytes. The extension is only a hint, and a file can carry another
/// container's name: an MPEG transport stream saved as .MOV is not a QuickTime movie, so neither AVFoundation's
/// QuickTime reader nor an FFmpeg demuxer forced by that extension can open it.
enum MediaContainer: Equatable {
    case quickTime, mpegTransportStream, avi, matroska, flv, asf, ogg, mpegProgramStream, realMedia

    var displayName: String {
        switch self {
        case .quickTime: return "QuickTime/MP4 movie"
        case .mpegTransportStream: return "MPEG transport stream"
        case .avi: return "AVI video"
        case .matroska: return "Matroska video"
        case .flv: return "Flash video"
        case .asf: return "Windows Media video"
        case .ogg: return "Ogg video"
        case .mpegProgramStream: return "MPEG program stream"
        case .realMedia: return "RealMedia video"
        }
    }

    /// The extension a player expects for this container.
    var canonicalExtension: String {
        switch self {
        case .quickTime: return "mov"
        case .mpegTransportStream: return "ts"
        case .avi: return "avi"
        case .matroska: return "mkv"
        case .flv: return "flv"
        case .asf: return "wmv"
        case .ogg: return "ogv"
        case .mpegProgramStream: return "mpg"
        case .realMedia: return "rm"
        }
    }

    /// What the player is told when it reads this container through a loader. Not derived from the extension,
    /// because `.ts` is also TypeScript.
    var contentType: UTType {
        switch self {
        case .quickTime: return .quickTimeMovie
        case .mpegTransportStream: return .mpeg2TransportStream
        case .avi: return .avi
        case .mpegProgramStream: return .mpeg
        default: return .movie
        }
    }

    /// The explicit demuxer for conversion: chosen by content, never probed by FFmpeg.
    var inputFormat: VideoPreviewPreparation.InputFormat {
        switch self {
        case .quickTime: return .mp4
        case .mpegTransportStream: return .ts
        case .avi: return .avi
        case .matroska: return .mkv
        case .flv: return .flv
        case .asf: return .wmv
        case .ogg: return .ogv
        case .mpegProgramStream: return .mpg
        case .realMedia: return .rm
        }
    }

    /// Whether a file with this extension is plausibly this container, so nothing needs correcting.
    func matches(fileExtension value: String) -> Bool {
        let value = value.lowercased()
        switch self {
        case .quickTime: return ["mov", "mp4", "m4v", "m4a", "3gp", "3g2", "qt"].contains(value)
        case .mpegTransportStream: return ["ts", "mts", "m2ts", "m2t"].contains(value)
        case .avi: return value == "avi"
        case .matroska: return ["mkv", "mk3d", "mka", "webm"].contains(value)
        case .flv: return ["flv", "f4v"].contains(value)
        case .asf: return ["wmv", "asf", "wma"].contains(value)
        case .ogg: return ["ogv", "ogg", "ogm", "oga"].contains(value)
        case .mpegProgramStream: return ["mpg", "mpeg", "mpe", "vob", "m2v"].contains(value)
        case .realMedia: return ["rm", "rmvb"].contains(value)
        }
    }

    /// Reads only the first kilobyte.
    static func sniff(_ url: URL) -> MediaContainer? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_024) else { return nil }
        return sniff(data)
    }

    static func sniff(_ data: Data) -> MediaContainer? {
        let bytes = Array(data.prefix(1_024))
        func has(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset ..< offset + prefix.count]) == prefix
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool { has(Array(text.utf8), at: offset) }
        /// Transport stream packets repeat their 0x47 sync byte at a fixed distance: 188 bytes, or 192 with a
        /// 4-byte timestamp in front. Three in a row is not an accident.
        func packets(every step: Int, from start: Int) -> Bool {
            (0..<3).allSatisfy { index in
                let position = start + index * step
                return position < bytes.count && bytes[position] == 0x47
            }
        }
        if packets(every: 188, from: 0) || packets(every: 192, from: 4) { return .mpegTransportStream }
        if bytes.count >= 12, ["ftyp", "moov", "mdat", "wide", "free", "skip", "junk", "pnot"].contains(where: { ascii($0, at: 4) }) { return .quickTime }
        if ascii("RIFF"), ascii("AVI ", at: 8) { return .avi }
        if has([0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        if ascii("FLV"), has([0x01], at: 3) { return .flv }
        if has([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) { return .asf }
        if ascii("OggS") { return .ogg }
        if has([0x00, 0x00, 0x01, 0xBA]) || has([0x00, 0x00, 0x01, 0xB3]) { return .mpegProgramStream }
        if ascii(".RMF") { return .realMedia }
        return nil
    }
}
