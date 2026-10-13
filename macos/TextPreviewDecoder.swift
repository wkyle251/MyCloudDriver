import Foundation

enum TextPreviewDecoder {
    static func decode(
        _ data: Data,
        responseEncodingName: String?,
        wasTruncated: Bool = false
    ) -> (text: String, encodingName: String)? {
        guard !data.isEmpty else { return ("", "UTF-8") }

        var candidates: [(String.Encoding, String)] = []
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            candidates.append((.utf8, "UTF-8"))
        } else if data.starts(with: [0xFF, 0xFE]) {
            candidates.append((.utf16LittleEndian, "UTF-16 LE"))
        } else if data.starts(with: [0xFE, 0xFF]) {
            candidates.append((.utf16BigEndian, "UTF-16 BE"))
        }

        if let responseEncodingName,
           let responseEncoding = textEncoding(named: responseEncodingName) {
            candidates.append(responseEncoding)
        }

        let sample = data.prefix(4_096)
        if sample.count >= 4 {
            var evenZeroes = 0
            var oddZeroes = 0
            for (index, byte) in sample.enumerated() where byte == 0 {
                if index.isMultiple(of: 2) {
                    evenZeroes += 1
                } else {
                    oddZeroes += 1
                }
            }
            if oddZeroes > max(sample.count / 10, 2) && evenZeroes <= oddZeroes / 4 {
                candidates.append((.utf16LittleEndian, "UTF-16 LE"))
            } else if evenZeroes > max(sample.count / 10, 2) && oddZeroes <= evenZeroes / 4 {
                candidates.append((.utf16BigEndian, "UTF-16 BE"))
            }
        }

        candidates.append(contentsOf: [
            (.utf8, "UTF-8"),
            (.windowsCP1252, "Windows-1252"),
            (.isoLatin1, "ISO-8859-1"),
        ])

        var tried = Set<UInt>()
        for (encoding, name) in candidates where tried.insert(encoding.rawValue).inserted {
            var decoded = String(data: data, encoding: encoding)
            if decoded == nil, wasTruncated,
               [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian].contains(encoding) {
                // The byte limit can bisect a scalar or surrogate pair. Only
                // trim its incomplete suffix; an invalid interior still fails.
                for suffix in 1...min(3, data.count) {
                    if isIncompleteSuffix(data, removing: suffix, encoding: encoding),
                       let text = String(data: data.dropLast(suffix), encoding: encoding) {
                        decoded = text
                        break
                    }
                }
            }
            guard var text = decoded, looksLikePlainText(text) else { continue }
            if text.first == "\u{FEFF}" {
                text.removeFirst()
            }
            return (text, name)
        }
        return nil
    }

    private static func isIncompleteSuffix(_ data: Data, removing count: Int, encoding: String.Encoding) -> Bool {
        let tail = Array(data.suffix(count))
        if encoding == .utf8 {
            guard let first = tail.first else { return false }
            let required: Int
            switch first {
            case 0xC2...0xDF: required = 2
            case 0xE0...0xEF: required = 3
            case 0xF0...0xF4: required = 4
            default: return false
            }
            guard tail.count < required, tail.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { return false }
            if tail.count > 1 {
                if first == 0xE0 && tail[1] < 0xA0 { return false }
                if first == 0xED && tail[1] > 0x9F { return false }
                if first == 0xF0 && tail[1] < 0x90 { return false }
                if first == 0xF4 && tail[1] > 0x8F { return false }
            }
            return true
        }
        let little = encoding == .utf16LittleEndian || (encoding == .utf16 && data.starts(with: [0xFF, 0xFE]))
        guard (data.count - count).isMultiple(of: 2) else { return false }
        // An odd final byte begins an incomplete code unit. A high surrogate
        // can also be cut before its matching low surrogate is complete.
        if count == 1 { return true }
        guard count == 2 || count == 3 else { return false }
        let unit = little ? UInt16(tail[0]) | UInt16(tail[1]) << 8 : UInt16(tail[0]) << 8 | UInt16(tail[1])
        guard (0xD800...0xDBFF).contains(unit) else { return false }
        return count == 2 || little || (0xDC...0xDF).contains(tail[2])
    }

    private static func textEncoding(
        named rawName: String
    ) -> (String.Encoding, String)? {
        let name = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch name {
        case "utf-8", "utf8": return (.utf8, "UTF-8")
        case "utf-16", "utf16": return (.utf16, "UTF-16")
        case "utf-16le": return (.utf16LittleEndian, "UTF-16 LE")
        case "utf-16be": return (.utf16BigEndian, "UTF-16 BE")
        case "us-ascii", "ascii": return (.ascii, "ASCII")
        case "windows-1252", "cp1252": return (.windowsCP1252, "Windows-1252")
        case "iso-8859-1", "latin1", "latin-1": return (.isoLatin1, "ISO-8859-1")
        default: return nil
        }
    }

    private static func looksLikePlainText(_ text: String) -> Bool {
        var inspected = 0
        var unsupportedControls = 0
        for scalar in text.unicodeScalars.prefix(40_000) {
            inspected += 1
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D:
                continue
            case 0x00 ..< 0x20, 0x7F:
                unsupportedControls += 1
            default:
                continue
            }
        }
        guard inspected > 0 else { return true }
        return unsupportedControls <= max(2, inspected / 100)
    }

}
