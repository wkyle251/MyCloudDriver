import CryptoKit
import Foundation

/// Exact checks need hashes, not media decoders or similarity vectors.
enum NativeDriveDuplicates {
    static func scan(_ roots: [URL], progress: @escaping @Sendable ([String: Any]) -> Void) async throws -> SimilarityReport {
        try await CloudDriveFiles.detached {
            let started = Date(), manager = FileManager.default
            var pending = roots, seen = Set<URL>(), files: [(URL, UInt64, Date?)] = [], issues: [SimilarityIssue] = []
            while let source = pending.popLast() {
                try Task.checkCancellation()
                guard seen.insert(source.standardizedFileURL).inserted else { continue }
                do {
                    let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey])
                    if values.isSymbolicLink == true || values.isHidden == true { continue }
                    if values.isDirectory == true {
                        pending.append(contentsOf: try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                    } else if values.isRegularFile == true {
                        files.append((source, UInt64(max(0, values.fileSize ?? 0)), values.contentModificationDate))
                    }
                } catch { issues.append(.init(path: source.path, reason: error.localizedDescription)) }
            }
            let sizeCounts = Dictionary(grouping: files, by: { $0.1 }).mapValues(\.count)
            var byHash: [String: [SimilarityFile]] = [:], checked = 0, last = Date.distantPast
            for (url, size, modified) in files {
                try Task.checkCancellation()
                do {
                    if sizeCounts[size, default: 0] > 1 {
                        let digest: String = try CloudDriveFiles.coordinated(url) { url in
                            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                            var digest = SHA256(), read: UInt64 = 0
                            while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                                try Task.checkCancellation(); digest.update(data: chunk); read += UInt64(chunk.count)
                                if Date().timeIntervalSince(last) > 0.2 {
                                    progress(["event":"progress", "stage":"analysing", "completed":checked, "total":files.count,
                                        "current_file":["name":url.lastPathComponent, "bytes":size], "file_bytes_read":read,
                                        "operation":"hashing", "counts":["files_ready":checked]])
                                    last = Date()
                                }
                            }
                            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                            guard read == size, UInt64(max(0, after.fileSize ?? 0)) == size, after.contentModificationDate == modified else {
                                throw CloudDriveError.message("The file changed during comparison. Scan it again.")
                            }
                            return digest.finalize().map { String(format: "%02x", $0) }.joined()
                        }
                        byHash[digest, default: []].append(.init(id: url.absoluteString, name: url.lastPathComponent, path: url.path,
                            bytes: size, family: "other", localPath: url.path, cloudId: nil, ancestors: []))
                    }
                    checked += 1
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    issues.append(.init(path: url.path, reason: error.localizedDescription))
                }
            }
            let matches = byHash.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
            var groups: [SimilarityGroup] = [], members = 0, truncated = false
            for (hash, files) in matches {
                if groups.count >= 2_000 || members + files.count > 20_000 { truncated = true; continue }
                members += files.count
                groups.append(.init(id: hash, matchKind: "byte_identical", family: "other", minimumScore: nil,
                    memberCount: UInt64(files.count), members: files.sorted { $0.path < $1.path }))
            }
            progress(["event":"progress", "stage":"grouping", "completed":groups.count, "total":groups.count, "counts":["files_ready":checked]])
            return .init(source: .local, scope: roots.map(\.path), status: issues.isEmpty ? "completed" : "partial", threshold: 1,
                scannedFiles: UInt64(files.count), analysedFiles: UInt64(checked), skippedFiles: UInt64(issues.count), downloadedBytes: 0,
                totalGroups: UInt64(matches.count), groups: groups, issues: Array(issues.prefix(500)), truncated: truncated || issues.count > 500,
                coverage: "Files with equal sizes were compared using SHA-256. Hidden files and symbolic links are excluded.", elapsedSeconds: Date().timeIntervalSince(started))
        }
    }
}
