# Keep Smallest in similarity results

Each group offers **Keep Smallest**, showing the retained file, its original size, and how many other files will move to Trash. The action runs directly. **Group Actions** also offers the same operation for every group at the current similarity threshold, including groups hidden by search. Files outside groups are untouched.

Selection uses original byte size. Equal sizes retain the first path in stable lexical order, then file ID. A zero-byte file is a valid candidate. Original identities are deduplicated and every group's keeper is protected across overlapping groups. The group snapshot is rejected if the scan, threshold, match type or membership changed. Controls prevent duplicate batch submissions.

Before deletion, Local Disk/iCloud refresh the retained originals and check their sizes. Photos verifies retained assets still exist in the connected library, without exporting their content. PikPak sends retained IDs and expected sizes with the batch request; the helper verifies all of them before its first Trash call. A failed preflight stops the operation without deleting anything.

Native providers use one batch operation, with one Undo/Redo for Local Disk and iCloud. Photos uses one PhotoKit change transaction and restores through Recently Deleted. PikPak batches at the existing API limit and records only acknowledged IDs in its account's Undo history. Partial failures leave unconfirmed files in the results. The saved comparison matrix is immutable; Trash/Undo changes visibility only. After a single-group success, All Files selects the retained file.

Validation: `SimilarityFileActionTests.swift` covers ties, empty files, overlap, stale groups, double clicks, partial acknowledgements, all native provider routes, account isolation and batch Undo. It also moves synthetic local files to Trash and restores their exact contents. `cargo test --bin pikpak trash_selection` covers keeper validation, batch ordering/partial results, and compatibility with existing ID-array requests. `SimilarityUITestApp.swift` exercises the production layout with simulated acknowledgements; UI tests delete no files.
