# Compressed similarity vector cache

MyCloudDriver stores `filetwin-vectors.f32.zst` below each scan scope's private
Application Support `Similarity` directory. This is an app-owned, versioned
container; FileTwin's public JSON interchange format remains unchanged.

The 48-byte header contains the eight-byte `MCDVEC01` format marker, a
little-endian 64-bit decompressed length, and a SHA-256 digest of the payload.
The rest is a Zstandard frame at compression level 9 with its frame checksum
enabled. The payload starts with an eight-byte metadata length and compact
JSON metadata (record information and dimensions), followed by four float32
byte planes. Every value retains its original little-endian IEEE-754 bits;
there is no quantisation or reduced precision. Grouping and similarity scores
therefore do not change because of compression.

Float embeddings usually have irregular mantissa bytes but repeated exponent
and sign patterns. Placing equivalent bytes together improves compression
compared with decimal JSON or interleaved raw float32 values. On a 488-record
local cache, the implemented format reduced 5,426,494 bytes to 1,016,056 bytes
(81.28%). A preliminary comparison found JSON plus Zstandard level 9 used
1,415,064 bytes. Zstandard level 15 saved less than another 1% on shuffled data
while taking about three times as long to encode; XZ level 6 saved about another
3% while taking about ten times as long. These are one-cache observations,
not a guarantee for every file type or cache.

Loading validates the format, declared length, frame and payload checksums,
record profiles, vector dimensions, normalisation and vector checksums.
Decompression is bounded to 192 MiB of vector/metadata payload, with a 64-MiB
decoder window. Stored vectors remain capped at 128 MiB and metadata at 64 MiB.
A corrupt or unsupported cache is ignored so the scan can rebuild it.

Legacy `filetwin-vectors.json` files are accepted and validated. Migration
removes a recognised JSON cache only after a private compressed replacement
has been atomically published and synced. Concurrent windows finishing scans
acquire the same scope-local `filetwin-vectors.lock`, reload and merge vectors,
then publish one replacement, preventing stale snapshots from losing entries.
Cache and lock files use owner-only permissions. Only temporary, private JSON
snapshots are written for FileTwin's encoder input; normal scan cleanup removes
those snapshots.

Tests cover exact float32 bits (including signed zero and subnormals), migration,
corruption, bounded decoding, concurrent merges, symlink refusal and successful
FileTwin reuse after decompression. A migration trial on a temporary copy of
the real cache checked every decoded float32 bit and left the source untouched.

## Reusing a vector before downloading (2.2.22)

`filetwin-sources.sqlite3` is an account/drive-local index checked during source
acquisition, before opening an original, requesting a Photos export, or reserving
download RAM. Its source key includes the provider/file ID and an unchanged
revision plus size. PikPak folder listings supply a content hash or modification
revision; directly selected files refresh that metadata on every scan. The
download response is associated with the revision returned with its signed URL,
so a long queue wait does not attach an original to stale discovery metadata.
Photos uses the asset's modification date, falling back to its creation date.
Local/iCloud paths use metadata-only inode, device, size, modification time and
change time checks, without opening an original just to check the cache.

Only validated, ready vectors for the current family and exact encoding profile
are reusable. Missing/changed revisions, mismatched profiles, unavailable or
corrupt records are misses. A miss can still reuse the existing content-hash
cache after reading the original. A cached filename alone is never sufficient.
The index is shared across windows for the same account or native drive; other
PikPak accounts use different directories.

Vectors are journalled as each file completes, using SQLite WAL transactions and
FULL synchronous writes. The index stores each content hash/profile only once,
with a lossless byte-shuffled float32 + Zstandard payload. It stores derived
vectors and revision metadata, never original media or signed download URLs.
Clearing a scan removes its results/checkpoint, while this reusable cache remains.

Completed binary/archive classifications with a full content hash are also
journalled immediately in the index's `outcomes` table. A later scan can reuse
the unsupported result and exact-copy hash without downloading the original.
It stays counted as unsupported, and can still match identical archives; it
does not become a successful similarity vector. The classification key includes
the effective filename extension and a fingerprint of FileTwin's format
recognizer source, so renamed decoder hints and recognition changes are retried.
Failed or interrupted reads/decoders are not cached as completed results.

Cache creation and completed-record write failures are surfaced before reporting
the work complete. Pause/Cancel keeps committed entries, including when another
original is still downloading. A fresh scan after Clear uses the same account's
per-file journal. Old unversioned unsupported checkpoint results are not imported
as classifications made by the current recognizer; they need one new pass.

Existing checkpoints are imported read-only at scan startup to recover old
source-to-vector associations. Their recorded revisions are used, never a new
revision read from a changed file. Old standalone vector JSON/compressed files
contain content hashes but no provider revisions; where no checkpoint association
exists, the original must be read once to establish a safe mapping.

Regression coverage includes a fresh PikPak scan issuing **zero original GETs**
and downloading **zero bytes** on its second pass; changed/missing revisions;
account isolation; a cached Photos scan with no provider responder; corrupt and
incompatible vectors; checkpoint migration; and reuse after clearing a scan.
The interruption fixture waits for four per-file commits while a fifth original
is stalled, cancels the scan, and verifies that resume downloads only that fifth
file. After removing its temporary checkpoint and aggregate vector file, a fresh
scan performs zero original GETs and retains exact-duplicate archive matches.

Confirmed password protection is a separate `password-v1` outcome. It is saved
immediately, reused across backends without downloading the same revision, and
shown as an excluded/unsupported file rather than a failed analysis. A complete
hash is retained when an earlier reader had one; a header-only exclusion never
invents a hash or exact-duplicate evidence. Changed or missing revisions are
checked again. Existing checkpoints are revisited once to import explicit ZIP
password-required failures from older versions, even if their vectors had already
been imported. Other decoder, network and timeout errors remain retryable.

New cloud ZIPs and ZIP-based documents receive bounded range probes before
original-memory admission: the first local header, the final 65,577 bytes, and
up to 256 KiB of the central directory when necessary. ZIP64 locators and 64-bit
directory offsets are supported, including an unencrypted first entry; a long
comment may require a separate 56-byte ZIP64 record read. Record lengths, disk
counts and bounds are validated against [PKWARE's ZIP specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).

RAR4 and RAR5 cloud archives receive header probes too, including `.partN.rar`
and legacy `.r00` volume names. The signature determines the parser, so a RAR
renamed to `.zip` is still recognised. Both encrypted archive headers (hidden
filenames) and encrypted file/service entries establish protection. The probe
seeks over packed member data using checked 64-bit sizes, so an unprotected
first entry does not force a full download to reach a later encrypted entry.
Header CRCs, variable-length integers, extra-record boundaries and source bounds
are validated using [RARLAB's format description](https://www.rarlab.com/technote.htm)
and the RAR4 header definitions in its UnRAR source. RAR metadata reads are
bounded to 4 MiB / 1,024 headers; self-extracting or unrecognised layouts remain
inconclusive. The probe does not extract archive contents or request passwords.

Only validated encryption flags establish a skip. Range, validator, layout or
format uncertainty falls back to the normal reader. Network failures and
timeouts retry the check instead of bypassing it, and provider throttling
retains its retry delay. Checks use the normal download timeout, not a separate
five-second cutoff. Probes are cancellable, pause with the scan, and share
download connection admission. These exclusions apply to similarity scans;
manually requested downloads to disk can still save protected archives.
PDF and ZIP readers also classify explicit password-required errors, which
avoids subsequent downloads when a preflight could not detect protection.
