#pragma once

// The resume record is useful only while its exact payload files are unchanged.
// No seed-mode shortcut: incomplete blocks still pass the torrent's piece hash.
#import <Foundation/Foundation.h>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/torrent_info.hpp>
#include <openssl/sha.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <stdexcept>

namespace lt = libtorrent;
namespace fs = std::filesystem;
using Bytes = std::vector<char>;
inline NSString* ns(std::string const& s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}
inline std::string str(id value) {
    if (![value isKindOfClass:NSString.class]) throw std::runtime_error("Expected text.");
    return [(NSString*)value UTF8String];
}
inline std::string hex(char const* data, size_t size) {
    std::string out; out.reserve(size * 2);
    for (size_t i = 0; i < size; ++i) {
        auto c = static_cast<unsigned char>(data[i]);
        out += "0123456789abcdef"[c >> 4]; out += "0123456789abcdef"[c & 15];
    }
    return out;
}
inline std::string sha(Bytes const& data) {
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256(reinterpret_cast<unsigned char const*>(data.data()), data.size(), digest);
    return hex(reinterpret_cast<char*>(digest), sizeof(digest));
}
inline Bytes bytes(NSData* data) {
    if (!data) return {};
    auto p = static_cast<char const*>(data.bytes); return {p, p + data.length};
}
inline NSData* nsdata(Bytes const& b) { return [NSData dataWithBytes:b.data() length:b.size()]; }
inline Bytes json(id value) {
    NSError* error = nil;
    auto d = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:&error];
    if (!d) throw std::runtime_error("Cannot encode state.");
    return bytes(d);
}
inline id parse(Bytes const& b) {
    return [NSJSONSerialization JSONObjectWithData:nsdata(b) options:0 error:nil];
}
inline Bytes readFile(fs::path const& path, size_t maximum = 64 * 1024 * 1024) {
    int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return {};
    struct stat s{};
    if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_size < 0 || uint64_t(s.st_size) > maximum) {
        close(fd); return {};
    }
    Bytes b(size_t(s.st_size)); size_t n = 0;
    while (n < b.size()) {
        auto r = read(fd, b.data() + n, b.size() - n);
        if (r <= 0) { close(fd); return {}; }
        n += size_t(r);
    }
    close(fd); return b;
}
inline void privateDirectory(fs::path const& path) {
    fs::create_directories(path);
    struct stat s{};
    if (lstat(path.c_str(), &s) || !S_ISDIR(s.st_mode) || s.st_uid != getuid())
        throw std::runtime_error("Unsafe torrent state directory.");
    if (chmod(path.c_str(), 0700)) throw std::runtime_error("Cannot protect torrent state.");
}
inline void atomicWrite(fs::path const& path, Bytes const& b) {
    auto temporary = path.string() + "." + str(NSUUID.UUID.UUIDString) + ".tmp";
    int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) throw std::runtime_error("Cannot save torrent state.");
    size_t n = 0; bool ok = true;
    while (n < b.size()) {
        auto r = write(fd, b.data() + n, b.size() - n);
        if (r <= 0) { ok = false; break; }
        n += size_t(r);
    }
    ok = fsync(fd) == 0 && ok; close(fd);
    if (!ok || rename(temporary.c_str(), path.c_str())) {
        unlink(temporary.c_str()); throw std::runtime_error("Cannot save torrent state.");
    }
    int parent = open(path.parent_path().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parent >= 0) { fsync(parent); close(parent); }
}
inline fs::path rootPath(std::string const& value) {
    fs::path root(value);
    if (!root.is_absolute() || value.find('\0') != std::string::npos)
        throw std::runtime_error("A local absolute download folder is required.");
    root = root.lexically_normal(); fs::create_directories(root);
    struct stat s{};
    if (lstat(root.c_str(), &s) || !S_ISDIR(s.st_mode))
        throw std::runtime_error("The download folder must not be a symbolic link.");
    return root;
}

// Walk every path component with openat/O_NOFOLLOW. The final operation keeps a
// descriptor for its parent, so replacing a directory with a symlink cannot
// redirect a release outside the selected payload root.
inline int fileParent(fs::path const& root, std::string const& relative, std::string& name) {
    fs::path p(relative);
    if (p.empty() || p.is_absolute() || relative.find('\0') != std::string::npos)
        throw std::runtime_error("Unsafe torrent file path.");
    for (auto const& c : p) if (c == ".." || c == "." || c.empty())
        throw std::runtime_error("Unsafe torrent file path.");
    int fd = open(root.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) throw std::runtime_error("Cannot open download folder safely.");
    name = p.filename().string();
    for (auto const& c : p.parent_path()) {
        int next = openat(fd, c.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int error = errno; close(fd);
        if (next < 0) {
            if (error == ENOENT) return -1;
            throw std::runtime_error("Unsafe or inaccessible torrent file directory.");
        }
        fd = next;
    }
    return fd;
}
inline bool fileStat(fs::path const& root, std::string const& relative, struct stat& s) {
    std::string name; int fd = fileParent(root, relative, name);
    if (fd < 0) return false;
    int result = fstatat(fd, name.c_str(), &s, AT_SYMLINK_NOFOLLOW);
    int error = errno; close(fd);
    if (result < 0) {
        if (error == ENOENT) return false;
        throw std::runtime_error("Cannot inspect torrent data.");
    }
    if (!S_ISREG(s.st_mode)) throw std::runtime_error("Torrent data must be regular files.");
    return true;
}
inline bool removeFile(fs::path const& root, std::string const& relative) {
    std::string name; int fd = fileParent(root, relative, name);
    if (fd < 0) return true;
    struct stat s{};
    int result = fstatat(fd, name.c_str(), &s, AT_SYMLINK_NOFOLLOW);
    if (result < 0) { int e = errno; close(fd); return e == ENOENT; }
    if (!S_ISREG(s.st_mode)) { close(fd); return false; }
    result = unlinkat(fd, name.c_str(), 0); close(fd); return result == 0;
}
inline void number(Bytes& out, uint64_t n) {
    for (int shift = 56; shift >= 0; shift -= 8) out.push_back(char(n >> shift));
}
inline void fingerprint(Bytes& out, fs::path const& root, std::string const& relative) {
    auto path = (root / relative).string(); number(out, path.size());
    out.insert(out.end(), path.begin(), path.end());
    struct stat s{};
    if (!fileStat(root, relative, s)) { number(out, 0); return; }
    number(out, 1); number(out, s.st_dev); number(out, s.st_ino); number(out, s.st_size);
    number(out, s.st_mtimespec.tv_sec); number(out, s.st_mtimespec.tv_nsec);
    number(out, s.st_ctimespec.tv_sec); number(out, s.st_ctimespec.tv_nsec);
}
inline std::string infoHash(lt::torrent_info const& ti) {
    auto h = ti.info_hashes();
    return h.has_v1() ? hex(h.v1.data(), 20) : hex(h.v2.data(), 32);
}
inline std::string manifest(lt::torrent_info const& ti, fs::path const& root) {
    Bytes b; auto const& files = ti.files(); number(b, files.num_files());
    for (auto i : files.file_range()) fingerprint(b, root, files.file_path(i));
    // Unselected boundary blocks may be stored here instead of in payload files.
    fingerprint(b, root, "." + hex(ti.info_hashes().get_best().data(), 20) + ".parts");
    return sha(b);
}
inline fs::path resumePath(fs::path const& state, lt::torrent_info const& ti, fs::path const& root) {
    auto key = infoHash(ti) + "\n" + root.string();
    return state / "Resume" / (sha(Bytes(key.begin(), key.end())) + ".json");
}
inline NSMutableArray* indexes(std::set<int> const& values) {
    NSMutableArray* a = [NSMutableArray array]; for (int i : values) [a addObject:@(i)]; return a;
}
inline std::set<int> indexSet(id array, int size) {
    if (![array isKindOfClass:NSArray.class]) throw std::runtime_error("Invalid saved file list.");
    std::set<int> result;
    for (id v in array) {
        if (![v isKindOfClass:NSNumber.class]) throw std::runtime_error("Invalid file index.");
        int i = [v intValue]; if (i < 0 || i >= size) throw std::runtime_error("File index outside torrent.");
        result.insert(i);
    }
    return result;
}

// A matching manifest proves the cache belongs to these files; an older engine
// can nevertheless have saved a piece map that claims bytes past EOF. Withdraw
// only those impossible claims, without reading payload or discarding usable
// verified pieces. Priority-zero native files may live in the partfile instead.
inline void reconcileResumeSizes(lt::torrent_info const& ti, fs::path const& root,
                                 lt::add_torrent_params& params, std::set<int>& complete,
                                 std::set<int> const& released, bool fromAria2) {
    auto const& files = ti.files();
    for (auto i : files.file_range()) {
        int n = int(i);
        if (files.pad_file_at(i) || released.count(n)) continue;
        if (!fromAria2 && n < int(params.file_priorities.size())
            && params.file_priorities[n] == lt::dont_download) continue;
        struct stat file{};
        int64_t size = fileStat(root, files.file_path(i), file) ? std::max<int64_t>(0, file.st_size) : 0;
        if (size != files.file_size(i)) complete.erase(n);
        if (size >= files.file_size(i)) continue;
        int64_t begin = files.file_offset(i) + size;
        int64_t end = files.file_offset(i) + files.file_size(i);
        int first = int(begin / ti.piece_length()), last = int((end - 1) / ti.piece_length());
        for (int p = first; p <= last; ++p) {
            auto piece = lt::piece_index_t(p);
            if (p < params.have_pieces.size()) params.have_pieces.clear_bit(piece);
            if (p < params.verified_pieces.size()) params.verified_pieces.clear_bit(piece);
        }
        for (auto p = params.unfinished_pieces.lower_bound(lt::piece_index_t(first));
             p != params.unfinished_pieces.end() && int(p->first) <= last; ++p) {
            int64_t offset = int64_t(int(p->first)) * ti.piece_length();
            for (int b = 0; b < p->second.size(); ++b) {
                int64_t block = offset + int64_t(b) * 16384;
                if (block < end && block + 16384 > begin) p->second.clear_bit(b);
            }
        }
    }
}

inline bool restoreResume(fs::path const& state, lt::torrent_info const& ti, fs::path const& root,
                          lt::add_torrent_params& params, std::set<int>& complete, std::set<int>& released) {
    try {
        id e = parse(readFile(resumePath(state, ti, root)));
        if (![e isKindOfClass:NSDictionary.class] || ![e[@"schema"] isEqual:@1]
            || ![e[@"hash"] isEqual:ns(infoHash(ti))] || ![e[@"root"] isEqual:ns(root.string())]
            || ![e[@"manifest"] isEqual:ns(manifest(ti, root))]) return false;
        if (![e[@"resume"] isKindOfClass:NSString.class]) return false;
        NSMutableDictionary* signedValue = [e mutableCopy]; [signedValue removeObjectForKey:@"checksum"];
        if (![e[@"checksum"] isEqual:ns(sha(json(signedValue)))]) return false;
        auto b = bytes([[NSData alloc] initWithBase64EncodedString:e[@"resume"] options:0]);
        if (b.empty()) return false;
        auto c = indexSet(e[@"complete"], ti.num_files());
        auto r = indexSet(e[@"released"], ti.num_files());
        lt::error_code ec; auto restored = lt::read_resume_data(b, ec);
        if (ec || restored.info_hashes != ti.info_hashes()) return false;
        params = std::move(restored); complete = std::move(c); released = std::move(r); return true;
    } catch (...) { return false; }
}
inline std::string saveResume(fs::path const& state, lt::torrent_info const& ti, fs::path const& root,
                       lt::add_torrent_params const& params, std::set<int> const& complete,
                       std::set<int> const& released) {
    auto b = lt::write_resume_data_buf(params);
    auto fingerprint = manifest(ti, root);
    NSMutableDictionary* envelope = [@{@"schema":@1, @"hash":ns(infoHash(ti)),
        @"root":ns(root.string()), @"manifest":ns(fingerprint),
        @"resume":[nsdata(b) base64EncodedStringWithOptions:0], @"complete":indexes(complete),
        @"released":indexes(released)} mutableCopy];
    envelope[@"checksum"] = ns(sha(json(envelope)));
    atomicWrite(resumePath(state, ti, root), json(envelope));
    return fingerprint;
}

struct Reader {
    Bytes const& b; size_t offset = 0;
    uint64_t n(size_t count) {
        if (count > 8 || offset + count > b.size()) throw std::runtime_error("Truncated old resume record.");
        uint64_t v = 0; for (size_t i = 0; i < count; ++i) v = (v << 8) | uint8_t(b[offset++]); return v;
    }
    Bytes take(size_t size) {
        if (size > b.size() - offset) throw std::runtime_error("Truncated old resume record.");
        Bytes v(b.begin() + offset, b.begin() + offset + size); offset += size; return v;
    }
};
inline bool bit(Bytes const& b, size_t i) { return i / 8 < b.size() && (uint8_t(b[i / 8]) & (0x80 >> (i % 8))); }
inline bool importAria2(lt::torrent_info const& ti, fs::path const& root, lt::add_torrent_params& params) {
    if (!ti.info_hashes().has_v1()) return false;
    try {
        auto record = readFile(root / (ti.name() + ".aria2"));
        if (record.empty()) return false;
        Reader r{record};
        if (r.n(2) != 1 || !(r.n(4) & 1) || r.n(4) != 20) return false;
        auto hash = r.take(20);
        if (hex(hash.data(), hash.size()) != infoHash(ti)) return false;
        auto piece = r.n(4), total = r.n(8); r.n(8); auto size = r.n(4);
        if (piece != uint64_t(ti.piece_length()) || total != uint64_t(ti.total_size())
            || size != uint64_t((ti.num_pieces() + 7) / 8)) return false;
        auto bits = r.take(size); auto count = r.n(4);
        if (count > uint64_t(ti.num_pieces())) return false;
        struct Partial { uint64_t length; Bytes bits; }; std::map<int, Partial> partial;
        for (uint64_t n = 0; n < count; ++n) {
            auto i = r.n(4), length = r.n(4), bytesCount = r.n(4);
            if (i >= uint64_t(ti.num_pieces()) || length != uint64_t(ti.piece_size(lt::piece_index_t(int(i))))
                || bytesCount != ((length + 16383) / 16384 + 7) / 8 || partial.count(int(i))) return false;
            partial.emplace(int(i), Partial{length, r.take(bytesCount)});
        }
        auto marker = r.take(8), digest = r.take(32);
        if (std::string(marker.begin(), marker.end()) != "MCVR0001" || r.offset != record.size()) return false;
        Bytes signedBytes = hash; number(signedBytes, piece); number(signedBytes, total);
        number(signedBytes, size); signedBytes.insert(signedBytes.end(), bits.begin(), bits.end());
        number(signedBytes, count);
        for (auto const& [i, p] : partial) {
            number(signedBytes, i); number(signedBytes, p.length); number(signedBytes, p.bits.size());
            signedBytes.insert(signedBytes.end(), p.bits.begin(), p.bits.end());
        }
        number(signedBytes, ti.num_files());
        for (auto i : ti.files().file_range()) fingerprint(signedBytes, root, ti.files().file_path(i));
        if (sha(signedBytes) != hex(digest.data(), digest.size())) return false;
        params.have_pieces.resize(ti.num_pieces(), false);
        for (int i = 0; i < ti.num_pieces(); ++i) if (bit(bits, i)) params.have_pieces.set_bit(lt::piece_index_t(i));
        for (auto const& [i, p] : partial) {
            lt::bitfield blocks(int((p.length + 16383) / 16384), false);
            for (int n = 0; n < blocks.size(); ++n) if (bit(p.bits, n)) blocks.set_bit(n);
            params.unfinished_pieces.emplace(lt::piece_index_t(i), std::move(blocks));
        }
        return true;
    } catch (...) { return false; }
}
