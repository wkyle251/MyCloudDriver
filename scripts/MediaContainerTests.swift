import AVFoundation
import AppKit
import Foundation

/// A video's real container decides how it is opened, not its extension: an MPEG transport stream stored under a
/// .MOV name must play, and a failure must say why. Generated media only; needs FFmpeg.

private final class FileProvider: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind = .local
    let root = CloudDriveLocation(id: "container-tests", title: "Test")
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL { item.url! }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: [], total: 0) }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}

@main @MainActor struct MediaContainerTests {
    static func ffmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x568:rate=30", "-f", "lavfi", "-i", "sine=frequency=440",
                             "-t", "4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"] + arguments
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0, "ffmpeg failed")
    }

    /// A 4K portrait HEVC + AAC transport stream, like the camera footage that failed.
    static func generate4K(at url: URL, seconds: Int = 6) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=2160x3840:rate=30", "-f", "lavfi", "-i", "sine=frequency=440",
                             "-t", "\(seconds)", "-c:v", "hevc_videotoolbox", "-b:v", "40M", "-tag:v", "hvc1", "-c:a", "aac", "-shortest", "-f", "mpegts", url.path]
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0, "ffmpeg failed")
    }
    /// Splices junk into the 188-byte packet grid and cuts the last packet, as in the damaged original. Apple's
    /// transport-stream reader then finds no video, or never finishes opening; FFmpeg resynchronizes.
    static func damaged(_ data: Data) -> Data {
        var out = Data(), seed: UInt32 = 7
        let packets = data.count / 188
        for index in 0..<packets {
            out.append(data[index * 188 ..< (index + 1) * 188])
            if index > 0, index % 700 == 0 {
                for _ in 0..<[37, 53, 91, 120][(index / 700) % 4] {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let byte = UInt8(truncatingIfNeeded: seed >> 16)
                    out.append(byte == 0x47 ? 0x10 : byte)
                }
            }
        }
        out.append(data[0 ..< 126])   // a cut final packet
        return out
    }

    static func argumentTests() {
        let format = VideoPreviewPreparation.InputFormat.ts
        let repackaged = VideoPreviewPreparation.arguments(mode: .repackage, format: format, input: "/in.mov", output: "/out.mp4", hardware: false, hevcTag: true)
        precondition(zip(repackaged, repackaged.dropFirst()).contains { $0 == "-c:v" && $1 == "copy" }, "Repackaging copies the video untouched: \(repackaged)")
        precondition(repackaged.contains("hvc1") && !repackaged.contains("libx264") && !repackaged.contains("h264_videotoolbox"), "HEVC is tagged for QuickTime and never re-encoded")
        precondition(!VideoPreviewPreparation.arguments(mode: .repackage, format: format, input: "/in.mov", output: "/out.mp4", hardware: false, hevcTag: false).contains("hvc1"))
        let hardware = VideoPreviewPreparation.arguments(mode: .transcode, format: format, input: "/in.mov", output: "/out.mp4", hardware: true, hevcTag: false)
        let hwIndex = hardware.firstIndex(of: "videotoolbox"), inputIndex = hardware.firstIndex(of: "-i")
        precondition(hardware.contains("h264_videotoolbox") && hwIndex != nil && inputIndex != nil && hwIndex! < inputIndex!, "Hardware decode is an input option: \(hardware)")
        let software = VideoPreviewPreparation.arguments(mode: .transcode, format: format, input: "/in.mov", output: "/out.mp4", hardware: false, hevcTag: false)
        precondition(software.contains("libx264") && !software.contains("h264_videotoolbox") && !software.contains("-hwaccel"))
        for arguments in [repackaged, hardware, software] {
            precondition(zip(arguments, arguments.dropFirst()).contains { $0 == "-f" && $1 == "mpegts" }, "The explicit demuxer is kept, never probed")
            precondition(arguments.contains("-sn") && arguments.contains("-dn") && arguments.last == "/out.mp4")
        }
        for arguments in [hardware, software] {
            precondition(arguments.contains { $0.hasPrefix("scale=") && $0.contains("1920") }, "A preview is never larger than 1920 on its long side")
        }
        print("PASS repackaging copies video, transcoding is hardware-first and downscaled, and the demuxer stays explicit")
    }

    // MARK: Handing a file to IINA

    static func externalPlayerTests(in directory: URL) throws {
        // Not installed anywhere: no button.
        precondition(ExternalMediaPlayer.iinaURL(lookup: { _ in nil }, fallbacks: []) == nil, "No IINA, no offer")
        // Found by bundle identifier, but only if the app is really there.
        let app = directory.appendingPathComponent("IINA.app", isDirectory: true)
        precondition(ExternalMediaPlayer.iinaURL(lookup: { _ in app }, fallbacks: []) == nil, "A stale registration for a missing app is ignored")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        precondition(ExternalMediaPlayer.iinaURL(lookup: { _ in app }, fallbacks: []) == app, "An installed IINA is found by its identifier")
        let other = directory.appendingPathComponent("Elsewhere/IINA.app", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        precondition(ExternalMediaPlayer.iinaURL(lookup: { _ in nil }, fallbacks: [directory.appendingPathComponent("Missing/IINA.app"), other]) == other,
                     "The usual Applications folders are searched when the system does not know it")
        // Opening hands over the original, read-only: the file is neither copied nor moved.
        let movie = directory.appendingPathComponent("Clip.avi")
        try Data("generated".utf8).write(to: movie)
        var opened: [(URL, URL)] = []
        let ok = ExternalMediaPlayer.open(movie, in: app, opener: { file, application in opened.append((file, application)); return true })
        precondition(ok && opened.count == 1 && opened[0].0 == movie && opened[0].1 == app, "The original file is handed to IINA")
        precondition(!ExternalMediaPlayer.open(directory.appendingPathComponent("gone.avi"), in: app, opener: { _, _ in preconditionFailure("Nothing to open") }),
                     "A file that is gone is not handed over")
        precondition(FileManager.default.fileExists(atPath: movie.path))
        print("PASS IINA is offered only when installed, and is handed the original file untouched")
    }

    // MARK: Recognizing a container by its content

    static func packets(_ size: Int, count: Int, offset: Int = 0) -> Data {
        var data = Data(count: offset + size * count)
        for index in 0..<count { data[offset + index * size] = 0x47 }
        return data
    }
    static func atom(_ type: String) -> Data { Data([0, 0, 0, 24]) + Data(type.utf8) + Data(count: 16) }

    static func snifferTests() {
        precondition(MediaContainer.sniff(packets(188, count: 4)) == .mpegTransportStream, "188-byte packets")
        precondition(MediaContainer.sniff(packets(192, count: 4, offset: 4)) == .mpegTransportStream, "BDAV (M2TS) 192-byte packets")
        precondition(MediaContainer.sniff(Data([0x47]) + Data(count: 1_000)) == nil, "One 0x47 byte is not a stream: the packets must line up")
        precondition(MediaContainer.sniff(Data([0x47, 0x40, 0x11, 0x10, 0x00, 0x42])) == nil, "Too short to show a packet grid")
        for type in ["ftyp", "moov", "mdat", "wide", "free", "skip"] {
            precondition(MediaContainer.sniff(atom(type)) == .quickTime, "QuickTime/MP4 starting with \(type)")
        }
        precondition(MediaContainer.sniff(Data("RIFF".utf8) + Data(count: 4) + Data("AVI ".utf8) + Data(count: 8)) == .avi)
        precondition(MediaContainer.sniff(Data("RIFF".utf8) + Data(count: 4) + Data("WAVE".utf8) + Data(count: 8)) == nil, "WAVE is not a video container")
        precondition(MediaContainer.sniff(Data([0x1A, 0x45, 0xDF, 0xA3]) + Data(count: 16)) == .matroska)
        precondition(MediaContainer.sniff(Data("FLV".utf8) + Data([1, 5]) + Data(count: 16)) == .flv)
        precondition(MediaContainer.sniff(Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) + Data(count: 16)) == .asf)
        precondition(MediaContainer.sniff(Data("OggS".utf8) + Data(count: 16)) == .ogg)
        precondition(MediaContainer.sniff(Data([0, 0, 1, 0xBA]) + Data(count: 16)) == .mpegProgramStream)
        precondition(MediaContainer.sniff(Data(".RMF".utf8) + Data(count: 16)) == .realMedia)
        precondition(MediaContainer.sniff(Data("not a movie at all, just text".utf8)) == nil)
        precondition(MediaContainer.sniff(Data()) == nil)

        precondition(MediaContainer.mpegTransportStream.matches(fileExtension: "ts") && MediaContainer.mpegTransportStream.matches(fileExtension: "M2TS"))
        precondition(!MediaContainer.mpegTransportStream.matches(fileExtension: "mov"), "A transport stream named .mov is a mismatch")
        precondition(MediaContainer.quickTime.matches(fileExtension: "mov") && MediaContainer.quickTime.matches(fileExtension: "mp4") && MediaContainer.quickTime.matches(fileExtension: "m4v"))
        precondition(MediaContainer.matroska.matches(fileExtension: "webm") && MediaContainer.matroska.matches(fileExtension: "mkv"))
        precondition(!MediaContainer.matroska.matches(fileExtension: "mp4"))
        precondition(MediaContainer.mpegTransportStream.canonicalExtension == "ts" && MediaContainer.quickTime.canonicalExtension == "mov")
        precondition(MediaContainer.mpegTransportStream.inputFormat == .ts && MediaContainer.matroska.inputFormat == .mkv && MediaContainer.quickTime.inputFormat == .mp4)
        // Only containers AVFoundation does not read are repackaged first; an MP4/MOV fails on its codec, which a copy keeps.
        precondition(!VideoPreviewPreparation.InputFormat.mp4.repackagingCanHelp)
        for format in [VideoPreviewPreparation.InputFormat.avi, .ts, .mkv, .webm, .flv, .wmv, .rm, .mpg, .ogv] {
            precondition(format.repackagingCanHelp, "\(format) is repackaged before it is converted")
        }
        print("PASS containers are recognized by their first bytes, and extensions are checked against them")
    }

    static func reasonTests() {
        func reason(_ output: String, _ container: MediaContainer? = .quickTime) -> String {
            VideoPreviewPreparation.failureReason(fromErrorOutput: output, input: URL(fileURLWithPath: "/Volumes/Disk/Folder/Clip.MOV"), container: container)
        }
        precondition(reason("[mov,mp4 @ 0x1] moov atom not found\n[in#0 @ 0x2] Error opening input: Invalid data found when processing input").contains("movie index"),
                     "A missing index says the file is incomplete")
        precondition(reason("[in#0 @ 0x1] Error opening input: Invalid data found when processing input").contains("not valid"))
        precondition(reason("[mov,mp4 @ 0x1] moov atom not found", nil).contains("does not start like any known video format"),
                     "A file that is no known video format is not called incomplete")
        precondition(reason("Decoder (codec xyz) not found for input stream #0:0").contains("codec"))
        precondition(reason("av_interleaved_write_frame(): No space left on device").contains("space"), "A full disk is not blamed on the file")
        let other = reason("[AVFilterGraph @ 0x1] Something unexpected in /Volumes/Disk/Folder/Clip.MOV happened")
        precondition(other.contains("Something unexpected") && !other.contains("/Volumes/Disk"), "Unknown output is shown without the path: \(other)")
        precondition(reason("").contains("damaged"), "No output keeps the generic sentence")
        print("PASS the converter's reason is shown in plain words, never with a path")
    }

    // MARK: The preview flow, as the view drives it

    fileprivate static func settle(_ model: NativeMediaPreviewModel, _ item: CloudDriveItem, provider: FileProvider) async -> Bool {
        model.prepare(item, provider: provider)
        for _ in 0..<400 where !model.ready && model.failure == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        if model.ready, let player = model.playback.player, let current = player.currentItem {
            for _ in 0..<200 where current.status == .unknown { try? await Task.sleep(nanoseconds: 50_000_000) }
            if current.status == .failed, let error = current.error { model.recoverVideo(error, player: player, item: item) }
            else if current.status == .readyToPlay, ((try? await current.asset.load(.tracks)) ?? []).allSatisfy({ $0.mediaType != .video }) {
                // What the video view does when the player opens but has nothing to show.
                model.recoverVideo(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.noSourceTrack.rawValue), player: player, item: item)
            }
        }
        for _ in 0..<1_200 where model.failure == nil && !(model.ready && model.playback.player?.currentItem?.status == .readyToPlay) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return model.ready && model.playback.player?.currentItem?.status == .readyToPlay
    }

    fileprivate static func flowTests(in directory: URL, defaults: UserDefaults) async throws {
        let provider = FileProvider()
        func item(_ url: URL) -> CloudDriveItem { .init(id: url.lastPathComponent, name: url.lastPathComponent, isFolder: false, url: url, mediaType: "video") }
        func model(external: Bool) -> NativeMediaPreviewModel {
            let model = NativeMediaPreviewModel(settings: MediaPlaybackSettings(defaults: defaults))
            model.bufferedVolume = { _ in external ? .externalDisk : nil }; model.memoryBlockSize = 16 * 1_024
            return model
        }
        func assetURL(_ model: NativeMediaPreviewModel) -> URL? { (model.playback.player?.currentItem?.asset as? AVURLAsset)?.url }

        // The reported case: an MPEG transport stream under a .MOV name.
        let ts = directory.appendingPathComponent("Clip.MOV")
        try ffmpeg(["-f", "mpegts", ts.path])
        precondition(MediaContainer.sniff(ts) == .mpegTransportStream)
        do {
            let m = model(external: false)
            let played = await settle(m, item(ts), provider: provider)
            precondition(played && m.failure == nil, "A transport stream named .MOV plays: \(m.failure ?? "ready=\(m.ready)")")
            precondition(m.originalURL == ts && !m.isPreparingCopy, "The original is known, so it can be handed to another player")
            precondition(assetURL(m)?.pathExtension.lowercased() == "ts", "It is opened as the transport stream it is: \(String(describing: assetURL(m)))")
            precondition(assetURL(m) != ts && FileManager.default.fileExists(atPath: ts.path), "The original is only linked to, never moved")
            m.clear()
            precondition(FileManager.default.fileExists(atPath: ts.path), "Clearing the preview leaves the original in place")
        }
        do {
            let m = model(external: true)
            let played = await settle(m, item(ts), provider: provider)
            precondition(played && m.failure == nil && m.memoryLoader != nil, "On an external disk it plays through the RAM buffer too: \(m.failure ?? "ready=\(m.ready)")")
            precondition(assetURL(m)?.scheme == FilePreviewResourceLoader.scheme && assetURL(m)?.pathExtension.lowercased() == "ts",
                         "The buffer tells the player the stream's real type: \(String(describing: assetURL(m)))")
            m.clear()
        }
        print("PASS a transport stream named .MOV plays natively, from an internal or an external disk, without being moved")

        // Another mismatch the FFmpeg fallback must read by content: Matroska under an .mp4 name.
        let mkv = directory.appendingPathComponent("Clip.mp4")
        try ffmpeg(["-f", "matroska", mkv.path])
        do {
            let m = model(external: false)
            let played = await settle(m, item(mkv), provider: provider)
            precondition(played && m.failure == nil, "Matroska named .mp4 is converted by its real format: \(m.failure ?? "ready=\(m.ready)")")
            m.clear()
        }
        print("PASS the converter reads the real container, so a mislabelled file is still prepared")

        // The reported footage: a damaged 4K stream. Repackaging without re-encoding makes it playable at once.
        let clip = directory.appendingPathComponent("clip.ts")
        print("  [step] generating 4K clip"); try generate4K(at: clip); print("  [step] clip ready")
        let broken = directory.appendingPathComponent("Broken.MOV")
        try damaged(Data(contentsOf: clip)).write(to: broken)
        do {
            let m = model(external: false)
            let started = Date()
            print("  [step] preview of the damaged stream")
            let played = await settle(m, item(broken), provider: provider)
            print("  [step] settled: played=\(played) preparation=\(String(describing: m.preparation)) failure=\(m.failure ?? "none")")
            let took = Date().timeIntervalSince(started)
            precondition(played && m.failure == nil, "A damaged transport stream becomes playable: \(m.failure ?? "ready=\(m.ready)")")
            precondition(m.preparation == .repackaged, "It was repackaged, not re-encoded: \(String(describing: m.preparation))")
            precondition(took < 30, "Repackaging 4K takes seconds, not minutes: \(took)s")
            print("  [step] loading tracks")
            let tracks = try await (m.playback.player!.currentItem!.asset as! AVURLAsset).load(.tracks)
            precondition(tracks.contains { $0.mediaType == .video } && tracks.contains { $0.mediaType == .audio }, "Video and audio both survive")
            precondition(FileManager.default.fileExists(atPath: broken.path), "The original is untouched")
            // A repackaged copy that still cannot play moves on to a real conversion, once.
            let player = m.playback.player!, current = player.currentItem!
            m.recoverVideo(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue), player: player, item: item(broken))
            _ = current
            for _ in 0..<1_200 where m.failure == nil && !(m.preparation == .transcoded && m.ready && m.playback.player?.currentItem?.status == .readyToPlay) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            precondition(m.preparation == .transcoded && m.failure == nil && m.ready, "A second failure converts: \(String(describing: m.preparation)) \(m.failure ?? "")")
            m.clear()
        }
        print("PASS a damaged 4K transport stream is repackaged in seconds, keeps video and audio, and a copy that fails again is converted")

        // A player that never finishes opening must not leave the preview waiting.
        do {
            let m = model(external: false)
            m.openTimeout = 0.4; m.openStatus = { _ in .unknown }
            let started = Date()
            _ = await settle(m, item(ts), provider: provider)
            // The simulated stall keeps the player "opening", so after the timeout the preview moves to a repackaged copy.
            for _ in 0..<600 where m.preparation != .repackaged || !m.ready { try? await Task.sleep(nanoseconds: 50_000_000) }
            precondition(m.preparation == .repackaged && m.ready && m.failure == nil, "A stalled open falls back to repackaging: \(String(describing: m.preparation)) \(m.failure ?? "")")
            precondition(Date().timeIntervalSince(started) < 30)
            m.clear()
        }
        print("PASS a player that never finishes opening is abandoned after a timeout and the file is repackaged")

        // A normal movie is untouched.
        let normal = directory.appendingPathComponent("Normal.mov")
        try ffmpeg(["-f", "mov", normal.path])
        do {
            let m = model(external: false)
            let played = await settle(m, item(normal), provider: provider)
            precondition(played && assetURL(m) == normal, "A genuine QuickTime movie still plays from its own path")
            m.clear()
        }

        // Real failures say why.
        let size = try FileManager.default.attributesOfItem(atPath: normal.path)[.size] as! UInt64
        let cut = directory.appendingPathComponent("Cut.MOV")
        try Data(contentsOf: normal).prefix(Int(size) - Int(size) / 5).write(to: cut)
        do {
            let m = model(external: false)
            let played = await settle(m, item(cut), provider: provider)
            precondition(!played, "A cut-off movie cannot play")
            let message = m.failure ?? ""
            precondition(message.contains("movie index") && message.hasPrefix("The MP4 preview could not be prepared."), "It says the index is missing: \(message)")
            m.clear()
        }
        let junk = directory.appendingPathComponent("Junk.mov")
        try Data((0..<60_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) }).write(to: junk)
        do {
            let m = model(external: false)
            let played = await settle(m, item(junk), provider: provider)
            precondition(!played)
            let message = m.failure ?? ""
            precondition(message.contains("not valid") && !message.contains(directory.path), "Garbage is reported as invalid data, without a path: \(message)")
            m.clear()
        }
        print("PASS genuine failures say why: a missing movie index, or data that is not valid for its type")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MediaContainerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MyCloudDriver.MediaContainerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        snifferTests()
        try externalPlayerTests(in: directory)
        argumentTests()
        reasonTests()
        try await flowTests(in: directory, defaults: defaults)
    }
}
