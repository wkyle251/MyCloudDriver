import Foundation

/// A small durable mask preserves saved matrix ordinals and Undo across window
/// closure. The helper owns atomic updates and source-vector retirement.
enum SimilarityResultExclusions {
    private struct Saved: Decodable {
        let version: Int
        let runId: String
        let resultRevision: UInt64
        let ordinals: Set<UInt64>
    }
    static func load(_ report: SimilarityReport, configuration: SimilarityConfiguration?) throws -> Set<UInt64> {
        guard let configuration, let run = report.runId, let revision = report.resultRevision,
              run.hasPrefix("mcd2-"), run.count == 37, run.dropFirst(5).allSatisfy(\.isHexDigit) else { return [] }
        let path = configuration.dataDirectory.appendingPathComponent("runs").appendingPathComponent(run + ".excluded.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let data = SimilaritySessionStore.readBoundedFile(path, maximumBytes: 64 << 20) else {
            throw CloudDriveError.message("The saved Trash state could not be read. Reopen these results to retry.")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let saved = try decoder.decode(Saved.self, from: data)
        guard saved.version == 1, saved.runId == run, saved.resultRevision == revision else {
            throw CloudDriveError.message("The saved Trash state belongs to another comparison revision.")
        }
        return saved.ordinals
    }
}
