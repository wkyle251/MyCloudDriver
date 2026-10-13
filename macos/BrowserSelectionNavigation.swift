/// Remembers the gap left by a deleted selection. Surviving row identities, rather than a numeric
/// index, keep navigation correct when an expanded folder also removes its children or a batch is deleted.
struct DeletedBrowserSelection<ID: Hashable> {
    private let preceding: [ID]
    private let following: [ID]

    init?(visibleIDs: [ID], selectedID: ID?) {
        guard let selectedID, let index = visibleIDs.firstIndex(of: selectedID) else { return nil }
        preceding = Array(visibleIDs[..<index].reversed())
        following = Array(visibleIDs[(index + 1)...])
    }

    func targetIndex(in visibleIDs: [ID], offset: Int) -> Int? {
        guard offset != 0 else { return nil }
        var positions: [ID: Int] = [:]
        for (index, id) in visibleIDs.enumerated() { positions[id] = index }
        let index: Int
        if offset < 0 {
            guard let previous = preceding.lazy.compactMap({ positions[$0] }).first else { return nil }
            index = previous + offset + 1
        } else {
            guard let next = following.lazy.compactMap({ positions[$0] }).first else { return nil }
            index = next + offset - 1
        }
        return visibleIDs.indices.contains(index) ? index : nil
    }
}
