import Foundation

/// A snapshot of the groups the user reviewed. Original identity, rather than
/// score-row identity, protects keepers even if groups contain overlapping files.
/// Both size policies use the existing guarded provider batch contract.
struct SimilarityKeepSmallestPlan {
    enum SizePolicy: Hashable {
        case smallest, largest
        var actionTitle: String { self == .smallest ? "Keep Smallest" : "Keep Largest" }
        var adjective: String { self == .smallest ? "smallest" : "largest" }
    }

    let session: UUID
    let groupIDs: Set<String>
    let minimumScore: Double
    let identicalOnly: Bool
    let policy: SizePolicy
    let keepers: [SimilarityFile]
    let removals: [SimilarityFile]
    let removalIDs: Set<String>
    let bytesToRemove: UInt64

    static func originalID(_ file: SimilarityFile) -> String {
        if let id = file.cloudId, !id.isEmpty { return "cloud:" + id }
        // These are known files. Inferring whether each URL is a directory can
        // issue a filesystem request per result, including on sleeping disks.
        if let path = file.localPath { return "local:" + URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path }
        return "file:" + file.id
    }

    static func smallest(in files: [SimilarityFile]) -> SimilarityFile? {
        selected(in: files, policy: .smallest)
    }

    static func largest(in files: [SimilarityFile]) -> SimilarityFile? {
        selected(in: files, policy: .largest)
    }

    private static func selected(in files: [SimilarityFile], policy: SizePolicy) -> SimilarityFile? {
        files.min {
            if $0.bytes != $1.bytes { return policy == .smallest ? $0.bytes < $1.bytes : $0.bytes > $1.bytes }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.id < $1.id
        }
    }

    init(groups: [SimilarityResultGroup], session: UUID, minimumScore: Double, identicalOnly: Bool,
         policy: SizePolicy = .smallest) {
        self.session = session; self.minimumScore = minimumScore; self.identicalOnly = identicalOnly
        self.policy = policy
        let groups = groups.filter { $0.members.count > 1 }
        groupIDs = Set(groups.map(\.id))
        var originals: [String: String] = [:]
        func original(_ file: SimilarityFile) -> String {
            if let id = originals[file.id] { return id }
            let id = Self.originalID(file); originals[file.id] = id
            return id
        }
        var seenKeepers = Set<String>()
        keepers = groups.compactMap { Self.selected(in: $0.members, policy: policy) }
            .filter { seenKeepers.insert(original($0)).inserted }
        let protected = seenKeepers
        var seenRemovals = Set<String>()
        var removals: [SimilarityFile] = [], ids = Set<String>(), bytes: UInt64 = 0
        for group in groups {
            for file in group.members {
                let id = original(file)
                guard !protected.contains(id), seenRemovals.insert(id).inserted else { continue }
                removals.append(file); ids.insert(file.id)
                let sum = bytes.addingReportingOverflow(file.bytes)
                bytes = sum.overflow ? .max : sum.partialValue
            }
        }
        self.removals = removals; removalIDs = ids; bytesToRemove = bytes
    }

    var actionTitle: String { policy.actionTitle }
}
