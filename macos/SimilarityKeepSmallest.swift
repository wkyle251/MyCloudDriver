import Foundation

/// A snapshot of the groups the user reviewed. Original identity, rather than
/// score-row identity, protects keepers even if groups contain overlapping files.
struct SimilarityKeepSmallestPlan {
    let session: UUID
    let groupIDs: Set<String>
    let minimumScore: Double
    let identicalOnly: Bool
    let keepers: [SimilarityFile]
    let removals: [SimilarityFile]

    static func originalID(_ file: SimilarityFile) -> String {
        if let id = file.cloudId, !id.isEmpty { return "cloud:" + id }
        if let path = file.localPath { return "local:" + URL(fileURLWithPath: path).standardizedFileURL.path }
        return "file:" + file.id
    }

    static func smallest(in files: [SimilarityFile]) -> SimilarityFile? {
        files.min {
            if $0.bytes != $1.bytes { return $0.bytes < $1.bytes }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.id < $1.id
        }
    }

    init(groups: [SimilarityResultGroup], session: UUID, minimumScore: Double, identicalOnly: Bool) {
        self.session = session; self.minimumScore = minimumScore; self.identicalOnly = identicalOnly
        let groups = groups.filter { $0.members.count > 1 }
        groupIDs = Set(groups.map(\.id))
        var seenKeepers = Set<String>()
        keepers = groups.compactMap { Self.smallest(in: $0.members) }
            .filter { seenKeepers.insert(Self.originalID($0)).inserted }
        let protected = Set(keepers.map(Self.originalID))
        var seenRemovals = Set<String>()
        removals = groups.flatMap(\.members).filter {
            !protected.contains(Self.originalID($0)) && seenRemovals.insert(Self.originalID($0)).inserted
        }
    }

    var removalIDs: Set<String> { Set(removals.map(\.id)) }
    var bytesToRemove: UInt64 {
        removals.reduce(0) { total, file in
            let sum = total.addingReportingOverflow(file.bytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }
}
