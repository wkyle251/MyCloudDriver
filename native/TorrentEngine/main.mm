#import <Security/Security.h>
#include "Storage.hpp"
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/ip_filter.hpp>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>
#include <signal.h>
#include <chrono>
#include <functional>
#include <fstream>
#include <sstream>
#include <iostream>
#include <memory>
#include <algorithm>

using Clock = std::chrono::steady_clock;
using Options = std::map<std::string, std::string>;
static volatile sig_atomic_t stopping = 0;
static void stopSignal(int) { stopping = 1; }
static NSString* countString(int64_t n) { return ns(std::to_string(std::max<int64_t>(0, n))); }
static bool enabled(Options const& o, std::string const& k, bool fallback = true) {
    auto i = o.find(k); return i == o.end() ? fallback : i->second == "true";
}
static int integer(std::string const& value, int fallback = 0) {
    if (value.empty()) return fallback;
    size_t end = 0; auto n = std::stoll(value, &end); int64_t multiplier = 1;
    if (end < value.size()) {
        if (end + 1 != value.size()) throw std::runtime_error("Invalid numeric option.");
        switch (value[end]) { case 'K': multiplier = 1024; break; case 'M': multiplier = 1024 * 1024; break;
            case 'G': multiplier = 1024LL * 1024 * 1024; break; default: throw std::runtime_error("Invalid numeric option."); }
    }
    if (n < 0 || n > INT_MAX / multiplier) throw std::runtime_error("Numeric option is out of range.");
    return int(n * multiplier);
}
static Options options(id dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class]) throw std::runtime_error("Expected options.");
    Options result; for (id key in dictionary) result.emplace(str(key), str(dictionary[key])); return result;
}
static NSMutableDictionary* dictionary(Options const& options) {
    auto d = [NSMutableDictionary dictionary]; for (auto const& [k,v] : options) d[ns(k)] = ns(v); return d;
}
static std::set<int> selection(std::string const& value, int files) {
    std::set<int> result;
    if (value.empty()) { for (int n = 0; n < files; ++n) result.insert(n); return result; }
    std::istringstream stream(value); std::string segment;
    while (std::getline(stream, segment, ',')) {
        auto dash = segment.find('-');
        int first = integer(segment.substr(0, dash));
        int last = dash == std::string::npos ? first : integer(segment.substr(dash + 1));
        if (first < 1 || last < first || last > files) throw std::runtime_error("Invalid file selection.");
        for (int i = first; i <= last; ++i) result.insert(i - 1);
    }
    if (result.empty()) throw std::runtime_error("Select at least one file.");
    return result;
}

struct Job {
    std::string gid;
    std::shared_ptr<lt::torrent_info> ti;
    lt::torrent_handle handle;
    lt::add_torrent_params magnet;
    fs::path root;
    Options options;
    std::set<int> selected, complete, released;
    std::string resumeSource = "check", saveError, savedManifest, lastPeerError;
    std::map<std::string, int> peerFailures;
    bool metadataOnly = false, metadataDone = false, paused = true, started = false, saving = false;
    bool relay = false, finished = false;
    unsigned flushed = 0, pauses = 0, saves = 0, priorities = 0;
    /// Pieces currently carrying a completion deadline. Tracked so each one can
    /// be handed back its ordinary priority when the focused set moves on:
    /// libtorrent drops a cleared time-critical piece to low priority.
    std::set<int> deadlined;
    Clock::time_point lastSaved = Clock::now(), focused{};
};

static lt::settings_pack settings(Options const& o) {
    lt::settings_pack s;
    auto option = [&](std::string const& key, std::string value) {
        auto i = o.find(key); return i == o.end() ? value : i->second;
    };
    std::string port = option("listen-port", "49189"); integer(port);
    s.set_str(lt::settings_pack::listen_interfaces, option("lt-listen-interfaces", "0.0.0.0:" + port + ",[::]:" + port));
    s.set_str(lt::settings_pack::user_agent, "MyCloudDriver/libtorrent/" LIBTORRENT_VERSION);
    s.set_str(lt::settings_pack::peer_fingerprint, "-MC2300-");
    s.set_bool(lt::settings_pack::enable_dht, enabled(o, "enable-dht"));
    s.set_bool(lt::settings_pack::enable_lsd, enabled(o, "bt-enable-lpd", false));
    // The app owns NAT-PMP/UPnP mapping and reports the actual mapping state.
    s.set_bool(lt::settings_pack::enable_upnp, false);
    s.set_bool(lt::settings_pack::enable_natpmp, false);
    s.set_bool(lt::settings_pack::enable_incoming_tcp, enabled(o, "lt-enable-tcp"));
    s.set_bool(lt::settings_pack::enable_outgoing_tcp, enabled(o, "lt-enable-tcp"));
    s.set_bool(lt::settings_pack::enable_incoming_utp, enabled(o, "lt-enable-utp"));
    s.set_bool(lt::settings_pack::enable_outgoing_utp, enabled(o, "lt-enable-utp"));
    s.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, enabled(o, "lt-allow-same-ip", false));
    s.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    s.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    s.set_bool(lt::settings_pack::no_recheck_incomplete_resume, false);
    s.set_int(lt::settings_pack::connections_limit, integer(option("bt-max-peers", "100")));
    // libtorrent waits (failures + 1) x min_reconnect_time before redialing a
    // peer and writes it off after three failures. The default is libtorrent's
    // own; tests shorten it so a written-off peer can be observed in seconds.
    s.set_int(lt::settings_pack::min_reconnect_time, integer(option("lt-min-reconnect-time", "60")));
    s.set_int(lt::settings_pack::upload_rate_limit, integer(option("max-overall-upload-limit", "4M")));
    s.set_int(lt::settings_pack::download_rate_limit, integer(option("max-overall-download-limit", "0")));
    s.set_int(lt::settings_pack::active_downloads, 3);
    s.set_int(lt::settings_pack::active_seeds, 3);
    s.set_int(lt::settings_pack::active_limit, 6);
    auto encryption = option("lt-encryption", "enabled") == "disabled" ? lt::settings_pack::pe_disabled : lt::settings_pack::pe_enabled;
    s.set_int(lt::settings_pack::out_enc_policy, encryption);
    s.set_int(lt::settings_pack::in_enc_policy, encryption);
    s.set_bool(lt::settings_pack::prefer_rc4, enabled(o, "lt-prefer-rc4"));
    s.set_int(lt::settings_pack::alert_mask, int(lt::alert_category::error | lt::alert_category::storage
        | lt::alert_category::status | lt::alert_category::connect | lt::alert_category::peer));
    s.set_str(lt::settings_pack::dht_bootstrap_nodes,
        enabled(o, "enable-dht") ? option("dht-entry-point", "dht.transmissionbt.com:6881,router.bittorrent.com:6881,router.utorrent.com:6881") : "");
    return s;
}

class Engine {
    Options config;
    fs::path state;
    std::unique_ptr<lt::session> session;
    std::map<std::string, std::unique_ptr<Job>> jobs;
    Clock::time_point sessionSaved = Clock::now();
    struct DHTSnapshot { int nodes = 0, replacements = 0, requests = 0, timeouts = 0, responses = 0; };
    std::map<std::string, DHTSnapshot> dhtSnapshots;
    Clock::time_point dhtRequested = Clock::time_point::min();
public:
    explicit Engine(Options c, fs::path root) : config(std::move(c)), state(std::move(root)) {
        privateDirectory(state / "Resume");
        // Static OpenSSL uses the Mac's trusted anchors for HTTPS tracker checks.
        CFArrayRef anchors = nullptr;
        if (SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess && anchors) {
            NSMutableData* pem = [NSMutableData data];
            for (id item in (__bridge NSArray*)anchors) {
                id der = CFBridgingRelease(SecCertificateCopyData((__bridge SecCertificateRef)item));
                NSString* b64 = [(NSData*)der base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength | NSDataBase64EncodingEndLineWithLineFeed];
                [pem appendData:[[NSString stringWithFormat:@"-----BEGIN CERTIFICATE-----\n%@\n-----END CERTIFICATE-----\n", b64] dataUsingEncoding:NSUTF8StringEncoding]];
            }
            CFRelease(anchors); atomicWrite(state / "trusted-roots.pem", bytes(pem));
            setenv("SSL_CERT_FILE", (state / "trusted-roots.pem").c_str(), 1);
        }
        lt::session_params p(settings(config));
        auto saved = readFile(state / "libtorrent-dht.dat", 4 * 1024 * 1024);
        if (!saved.empty()) {
            try { p.dht_state = lt::read_session_params(saved, lt::session_handle::save_dht_state).dht_state; }
            catch (...) {}
        }
        session = std::make_unique<lt::session>(std::move(p));
        // Honor the app's upload budget for LAN peers as well as internet peers.
        lt::ip_filter rateClasses;
        rateClasses.add_rule(lt::make_address("0.0.0.0"), lt::make_address("255.255.255.255"), 1u << lt::session::global_peer_class_id);
        rateClasses.add_rule(lt::make_address("::"), lt::make_address("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"), 1u << lt::session::global_peer_class_id);
        session->set_peer_class_filter(rateClasses);
    }
    Job& job(std::string const& id) {
        auto j = jobs.find(id); if (j == jobs.end()) throw std::runtime_error("Unknown torrent download."); return *j->second;
    }
    Job* job(lt::torrent_handle const& h) {
        for (auto& [id, j] : jobs) if (j->handle == h) return j.get(); return nullptr;
    }
    void validate(Job& j) {
        if (!j.ti || j.ti->num_files() > 200000 || j.ti->num_pieces() > 8000000)
            throw std::runtime_error("Torrent metadata exceeds supported limits.");
        std::set<std::string> paths;
        for (auto i : j.ti->files().file_range()) {
            auto const& f = j.ti->files(); auto path = f.file_path(i);
            if (f.file_flags(i) & lt::file_storage::flag_symlink || !paths.insert(path).second)
                throw std::runtime_error("Torrent contains unsafe file paths.");
            struct stat s{}; fileStat(j.root, path, s);
        }
    }
    std::vector<int64_t> progress(Job& j) {
        if (!j.ti) return {};
        std::vector<int64_t> p(j.ti->num_files());
        if (j.handle.is_valid()) {
            auto current = j.handle.file_progress(lt::torrent_handle::piece_granularity);
            if (current.size() == p.size()) p = std::move(current);
            for (int i = 0; i < int(p.size()); ++i) {
                auto index = lt::file_index_t(i);
                if (j.ti->files().pad_file_at(index)) continue;
                if (j.released.count(i)) continue;
                if (p[i] == j.ti->files().file_size(index) || j.complete.count(i)) {
                    // Unselected bytes can exist only in a partfile. Their
                    // eventual payload file is not upload-ready until exported.
                    struct stat file{};
                    bool exists = fileStat(j.root, j.ti->files().file_path(index), file);
                    auto length = j.ti->files().file_size(index);
                    if (exists && file.st_size == length) j.complete.insert(i);
                    else {
                        j.complete.erase(i);
                        // The raw piece count is not an upload-ready file.
                        p[i] = exists && file.st_size < length ? std::min(p[i], int64_t(file.st_size)) : 0;
                    }
                }
            }
        }
        for (int i : j.complete) p[i] = j.ti->files().file_size(lt::file_index_t(i));
        return p;
    }
    std::vector<lt::download_priority_t> filePriorities(Job const& j) {
        std::vector<lt::download_priority_t> p(j.ti->num_files(), lt::dont_download);
        for (int i : j.selected) if (!j.released.count(i) && !j.ti->files().pad_file_at(lt::file_index_t(i))) p[i] = lt::default_priority;
        return p;
    }
    std::vector<lt::download_priority_t> piecePriorities(Job const& j) {
        std::vector<lt::download_priority_t> p(j.ti->num_pieces(), lt::dont_download);
        auto const& f = j.ti->files();
        for (int i : j.selected) {
            if (j.complete.count(i) || j.released.count(i)) continue;
            auto index = lt::file_index_t(i); auto size = f.file_size(index); if (!size) continue;
            if (f.pad_file_at(index)) continue;
            auto start = f.file_offset(index) / j.ti->piece_length();
            auto end = (f.file_offset(index) + size - 1) / j.ti->piece_length();
            for (int64_t piece = start; piece <= end; ++piece) p[size_t(piece)] = lt::default_priority;
        }
        return p;
    }
    void alerts() {
        std::vector<lt::alert*> a; session->pop_alerts(&a);
        for (auto* alert : a) {
            if (auto* stats = lt::alert_cast<lt::dht_stats_alert>(alert)) {
                DHTSnapshot snapshot;
                for (auto const& bucket : stats->routing_table) {
                    snapshot.nodes += bucket.num_nodes; snapshot.replacements += bucket.num_replacements;
                }
                for (auto const& lookup : stats->active_requests) {
                    snapshot.requests += lookup.outstanding_requests;
                    snapshot.timeouts += lookup.timeouts; snapshot.responses += lookup.responses;
                }
                auto const& endpoint = stats->local_endpoint;
                dhtSnapshots[endpoint.address().to_string() + ":" + std::to_string(endpoint.port())] = snapshot;
                continue;
            }
            auto* torrent = dynamic_cast<lt::torrent_alert*>(alert);
            if (!torrent) continue;
            Job* j = job(torrent->handle); if (!j) continue;
            auto peerFailure = [&](lt::error_code const& error) {
                if (!error) return;
                j->lastPeerError = error.message();
                if (j->peerFailures.count(j->lastPeerError) || j->peerFailures.size() < 12)
                    ++j->peerFailures[j->lastPeerError];
            };
            if (auto* disconnected = lt::alert_cast<lt::peer_disconnected_alert>(alert)) peerFailure(disconnected->error);
            if (auto* failed = lt::alert_cast<lt::peer_error_alert>(alert)) peerFailure(failed->error);
            if (lt::alert_cast<lt::cache_flushed_alert>(alert)) ++j->flushed;
            else if (lt::alert_cast<lt::torrent_paused_alert>(alert)) ++j->pauses;
            else if (lt::alert_cast<lt::file_prio_alert>(alert)) ++j->priorities;
            else if (auto* saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
                try { progress(*j); j->savedManifest = saveResume(state, *j->ti, j->root, saved->params, j->complete, j->released); j->saveError.clear(); }
                catch (...) { j->saveError = "Cannot save the verified torrent resume record."; }
                ++j->saves; j->saving = false; j->lastSaved = Clock::now();
            } else if (lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
                ++j->saves; j->saving = false; j->saveError = "Cannot checkpoint this torrent yet.";
            } else if (lt::alert_cast<lt::fastresume_rejected_alert>(alert)) {
                j->resumeSource = "check"; j->complete.clear(); j->released.clear();
            } else if (lt::alert_cast<lt::metadata_received_alert>(alert) && j->metadataOnly) {
                try {
                    j->ti = std::make_shared<lt::torrent_info>(*j->handle.torrent_file()); validate(*j);
                    lt::create_torrent creator(*j->ti);
                    atomicWrite(j->root / (infoHash(*j->ti) + ".torrent"), creator.generate_buf());
                    j->handle.pause(); j->metadataDone = true; j->paused = true;
                } catch (...) { j->saveError = "Torrent metadata could not be saved safely."; j->handle.pause(); }
            }
        }
    }
    void wait(std::function<bool()> predicate) {
        auto deadline = Clock::now() + std::chrono::seconds(10);
        while (!predicate()) {
            alerts(); if (predicate()) break;
            if (Clock::now() >= deadline) throw std::runtime_error("Torrent storage is still busy. Try again.");
            session->wait_for_alert(std::chrono::milliseconds(20));
        }
    }
    void save(Job& j, bool synchronous) {
        if (!j.handle.is_valid() || !j.ti || j.metadataOnly) return;
        if (j.saving) wait([&] { return !j.saving; });
        auto before = j.saves; j.saving = true; j.saveError.clear();
        j.handle.save_resume_data(lt::torrent_handle::flush_disk_cache | lt::torrent_handle::save_info_dict);
        if (synchronous) {
            wait([&] { return j.saves != before; });
            if (!j.saveError.empty()) throw std::runtime_error(j.saveError);
        }
    }
    void pause(Job& j) {
        if (j.handle.is_valid()) {
            if (!(j.handle.status().flags & lt::torrent_flags::paused)) {
                auto before = j.pauses; j.handle.pause(); wait([&] { return j.pauses != before; });
            }
            j.paused = true; save(j, true);
        } else j.paused = true;
    }
    void prioritize(Job& j) {
        if (!j.handle.is_valid() || !j.ti) return;
        progress(j);
        // Surrender the focused set before the selection moves: the piece
        // priorities restated below are what give these pieces an honest
        // priority again, whether they stay selected or not.
        for (int piece : j.deadlined) j.handle.reset_piece_deadline(lt::piece_index_t(piece));
        j.deadlined.clear();
        auto before = j.priorities; j.handle.prioritize_files(filePriorities(j));
        wait([&] { return j.priorities != before; });
        j.handle.prioritize_pieces(piecePriorities(j));
    }
    /// A positive integer from the job's options, else the engine's, else the
    /// built-in default. Zero is honored, so tuning can be switched off.
    int tuning(Job const& j, std::string const& key, int fallback) const {
        auto i = j.options.find(key);
        std::string value = i != j.options.end() ? i->second : std::string();
        if (value.empty()) { auto g = config.find(key); if (g != config.end()) value = g->second; }
        if (value.empty()) return fallback;
        try { auto n = integer(value); return n < 0 ? fallback : n; } catch (...) { return fallback; }
    }
    /// Whole files, not raw bytes, are what the relay can upload and reclaim,
    /// so bytes spread thinly over hundreds of half-finished files stay stuck
    /// in the buffer. Deadlines pull the files closest to done to the front of
    /// the picker. Every selected piece keeps its ordinary priority underneath,
    /// so a thin swarm never loses a peer merely for holding nothing focused.
    void focus(Job& j) {
        if (!j.handle.is_valid() || !j.ti || j.paused || j.metadataOnly || j.finished) return;
        int const pieceTarget = tuning(j, "lt-focus-pieces", 64);
        if (pieceTarget == 0) { unfocus(j); return; }
        int const fileLimit = tuning(j, "lt-focus-files", 256);
        auto const& f = j.ti->files();
        auto done = progress(j);
        if (done.size() != size_t(j.ti->num_files())) return;
        // Rank the unfinished selection by how little is left to fetch, so the
        // next file to become uploadable is the cheapest one to finish.
        std::vector<std::pair<int64_t, int>> ranked;
        for (int i : j.selected) {
            if (j.complete.count(i) || j.released.count(i)) continue;
            auto index = lt::file_index_t(i);
            if (f.pad_file_at(index)) continue;
            auto size = f.file_size(index);
            if (size <= 0 || done[i] >= size) continue;
            ranked.emplace_back(size - done[i], i);
        }
        std::sort(ranked.begin(), ranked.end());
        auto have = j.handle.status(lt::torrent_handle::query_pieces).pieces;
        std::set<int> next; std::vector<int> ordered; int taken = 0;
        for (auto const& [remaining, i] : ranked) {
            if (int(next.size()) >= pieceTarget || taken >= fileLimit) break;
            ++taken;
            auto index = lt::file_index_t(i);
            auto offset = f.file_offset(index), size = f.file_size(index);
            for (int64_t piece = offset / j.ti->piece_length(); piece <= (offset + size - 1) / j.ti->piece_length(); ++piece) {
                auto n = lt::piece_index_t(int(piece));
                if (int(piece) < have.size() && have[n]) continue;
                if (next.insert(int(piece)).second) ordered.push_back(int(piece));
            }
        }
        if (next == j.deadlined) return;
        for (int piece : j.deadlined)
            if (!next.count(piece)) j.handle.reset_piece_deadline(lt::piece_index_t(piece));
        // A deadline forces a piece to top priority and clearing one drops it to
        // low, both regardless of the selection, so restate the real priorities
        // before the new deadlines go on. Released files must never come back.
        j.handle.prioritize_pieces(piecePriorities(j));
        int rank = 0;
        for (int piece : ordered) j.handle.set_piece_deadline(lt::piece_index_t(piece), ++rank * 1000);
        j.deadlined = std::move(next);
    }
    void unfocus(Job& j) {
        if (j.deadlined.empty()) return;
        for (int piece : j.deadlined) j.handle.reset_piece_deadline(lt::piece_index_t(piece));
        j.deadlined.clear();
        if (j.ti) j.handle.prioritize_pieces(piecePriorities(j));
    }
    void start(Job& j) {
        if (j.handle.is_valid()) {
            if (j.paused && j.ti && !j.savedManifest.empty() && manifest(*j.ti, j.root) != j.savedManifest) {
                j.complete.clear(); j.released.clear(); j.resumeSource = "check";
                j.handle.force_recheck(); prioritize(j);
            }
            j.handle.clear_error(); j.handle.resume(); j.paused = false; j.finished = false; return;
        }
        lt::add_torrent_params p;
        if (j.metadataOnly) p = j.magnet;
        else {
            validate(j);
            if (restoreResume(state, *j.ti, j.root, p, j.complete, j.released)) j.resumeSource = "libtorrent";
            else if (importAria2(*j.ti, j.root, p)) j.resumeSource = "aria2-verified";
            if (j.resumeSource != "check")
                reconcileResumeSizes(*j.ti, j.root, p, j.complete, j.released, j.resumeSource == "aria2-verified");
            for (int i : j.selected) if (!j.complete.count(i)) j.released.erase(i);
            p.ti = j.ti; p.info_hashes = j.ti->info_hashes();
            p.file_priorities = filePriorities(j); p.piece_priorities = piecePriorities(j);
            if (j.ti->priv()) p.peers.clear();
        }
        p.save_path = j.root.string(); p.storage_mode = lt::storage_mode_sparse;
        p.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused | lt::torrent_flags::seed_mode);
        p.flags |= lt::torrent_flags::duplicate_is_error;
        if (j.metadataOnly) p.flags |= lt::torrent_flags::upload_mode | lt::torrent_flags::default_dont_download;
        if (!enabled(config, "enable-dht")) p.flags |= lt::torrent_flags::disable_dht;
        if (!enabled(config, "bt-enable-lpd", false)) p.flags |= lt::torrent_flags::disable_lsd;
        if (!enabled(config, "enable-peer-exchange")) p.flags |= lt::torrent_flags::disable_pex;
        if (j.options.count("bt-tracker") && (!j.ti || !j.ti->priv())) {
            std::istringstream stream(j.options["bt-tracker"]); std::string url;
            while (std::getline(stream, url, ',')) if (!url.empty()) p.trackers.push_back(url);
        }
        p.max_connections = integer(config["bt-max-peers"], 100);
        p.upload_limit = integer(j.options["max-upload-limit"], 0);
        lt::error_code error; j.handle = session->add_torrent(std::move(p), error);
        if (error) throw std::runtime_error("Could not start torrent: " + error.message());
        j.paused = false; j.started = true; j.finished = false;
    }
    NSMutableArray* files(Job& j, std::vector<int64_t> const& p) {
        auto result = [NSMutableArray array]; if (!j.ti) return result;
        auto const& f = j.ti->files();
        for (auto i : f.file_range()) [result addObject:@{@"index":countString(int(i) + 1),
            @"path":ns((j.root / f.file_path(i)).string()), @"length":countString(f.file_size(i)),
            @"padding":f.pad_file_at(i) ? @"true" : @"false",
            @"completedLength":countString(p[int(i)]), @"selected":j.selected.count(int(i)) ? @"true" : @"false", @"uris":@[]}];
        return result;
    }
    NSMutableArray* files(Job& j) { return files(j, progress(j)); }
    NSMutableDictionary* status(Job& j, id keys = nil) {
        lt::torrent_status s; if (j.handle.is_valid()) s = j.handle.status();
        bool checking = j.handle.is_valid() && !j.metadataOnly && (s.state == lt::torrent_status::checking_files
            || s.state == lt::torrent_status::checking_resume_data);
        auto p = progress(j); int64_t total = 0, completed = 0, verified = 0;
        auto received = j.handle.is_valid() && !checking ? j.handle.file_progress() : std::vector<int64_t>{};
        if (j.ti) for (int i : j.selected) {
            if (j.ti->files().pad_file_at(lt::file_index_t(i))) continue;
            total += j.ti->files().file_size(lt::file_index_t(i)); verified += p[i];
            completed += received.size() == p.size() ? std::max(p[i], received[i]) : p[i];
        }
        bool done = j.ti && !j.metadataOnly && !checking && verified == total && !j.selected.empty();
        if (done && !j.relay && !j.finished && j.started) { pause(j); j.finished = true; }
        NSString* stateName = s.errc || !j.saveError.empty() ? @"error" : (j.finished || j.metadataDone ? @"complete" : (j.paused ? @"paused" : @"active"));
        NSMutableDictionary* d = [@{@"gid":ns(j.gid), @"status":stateName, @"infoHash":j.ti ? ns(infoHash(*j.ti)) : @"",
            @"bittorrent":@{@"info":@{@"name":j.ti ? ns(j.ti->name()) : @"Torrent"}},
            @"totalLength":countString(checking && j.ti ? j.ti->total_size() : total),
            @"completedLength":countString(completed), @"pieceLength":countString(j.ti ? j.ti->piece_length() : 0),
            @"downloadSpeed":countString(s.download_payload_rate), @"uploadSpeed":countString(s.upload_payload_rate),
            @"connections":countString(s.num_connections), @"numSeeders":countString(s.num_seeds),
            @"errorMessage":ns(s.errc ? s.errc.message() : j.saveError), @"resumeSource":ns(j.resumeSource),
            @"engine":@"libtorrent", @"numPieces":countString(s.num_pieces),
            @"focusedPieces":countString(int64_t(j.deadlined.size())),
            @"allTimeDownload":countString(s.all_time_download), @"allTimeUpload":countString(s.all_time_upload)} mutableCopy];
        if (checking) {
            d[@"verifyIntegrityPending"] = @"true";
            d[@"verifiedLength"] = countString(int64_t(j.ti->total_size() * double(s.progress_ppm) / 1000000.0));
        }
        if (keys && [keys containsObject:@"pieceDiagnostics"] && j.handle.is_valid()) {
            auto missing = [NSMutableArray array]; auto priorities = j.handle.get_piece_priorities();
            for (int i = 0; i < int(priorities.size()); ++i)
                if (!j.handle.have_piece(lt::piece_index_t(i))) [missing addObject:@{@"index":@(i), @"priority":@(int(priorities[i]))}];
            d[@"pieceDiagnostics"] = @{@"state":@(int(s.state)), @"missing":missing,
                @"wanted":countString(s.total_wanted), @"wantedDone":countString(s.total_wanted_done),
                @"lastPeerError":ns(j.lastPeerError), @"failedBytes":countString(s.total_failed_bytes)};
        }
        // The summary and file rows share one fresh disk-validated snapshot.
        // Rechecking here used to walk every completed file a second time.
        if (!keys || [keys containsObject:@"files"]) d[@"files"] = files(j, p);
        return d;
    }
    id peers(Job& j) {
        auto result = [NSMutableArray array]; if (!j.handle.is_valid()) return result;
        std::vector<lt::peer_info> peers; j.handle.get_peer_info(peers);
        for (auto const& p : peers) {
            bool connected = !(p.flags & (lt::peer_info::connecting | lt::peer_info::handshake));
            auto client = ns(p.client);
            // Incoming source ports need not be the peer's listening port.
            // Leave unknown listening ports out of the app's reconnect cache.
            [result addObject:@{@"ip":ns(p.ip.address().to_string()),
                @"port":(p.flags & lt::peer_info::local_connection) ? countString(p.ip.port()) : @"",
                @"handshakeCompleted":connected ? @"true" : @"false", @"seeder":(p.flags & lt::peer_info::seed) ? @"true" : @"false",
                @"downloadSpeed":countString(p.payload_down_speed), @"uploadSpeed":countString(p.payload_up_speed),
                @"peerId":ns(hex(p.pid.data(), 20)), @"client":client ?: @"", @"transport":(p.flags & lt::peer_info::utp_socket) ? @"utp" : @"tcp",
                @"peerChoking":(p.flags & lt::peer_info::remote_choked) ? @"true" : @"false", @"amInterested":(p.flags & lt::peer_info::interesting) ? @"true" : @"false"}];
        }
        return result;
    }
    /// Network state only: no metadata names, hashes, tracker passkeys, file
    /// progress, filesystem validation or payload reads. Suitable for diagnosing
    /// a zero-peer transfer without inspecting what the user is downloading.
    id networkDiagnostics() {
        DHTSnapshot total;
        for (auto const& [endpoint, snapshot] : dhtSnapshots) {
            total.nodes += snapshot.nodes; total.replacements += snapshot.replacements;
            total.requests += snapshot.requests; total.timeouts += snapshot.timeouts; total.responses += snapshot.responses;
        }
        auto dht = [@{@"enabled":@(session->is_dht_running()), @"snapshotReady":@(!dhtSnapshots.empty())} mutableCopy];
        if (!dhtSnapshots.empty()) {
            dht[@"nodes"] = @(total.nodes); dht[@"replacementNodes"] = @(total.replacements);
            dht[@"requests"] = @(total.requests); dht[@"timeouts"] = @(total.timeouts); dht[@"responses"] = @(total.responses);
        }
        auto rows = [NSMutableArray array];
        for (auto& [id, j] : jobs) {
            lt::torrent_status s;
            std::vector<lt::peer_info> peers;
            std::vector<lt::announce_entry> trackers;
            if (j->handle.is_valid()) {
                // An empty status-flags mask requests counters only.
                s = j->handle.status({}); j->handle.get_peer_info(peers); trackers = j->handle.trackers();
            }
            int connected = 0;
            for (auto const& p : peers)
                if (!(p.flags & (lt::peer_info::connecting | lt::peer_info::handshake))) ++connected;
            auto announces = [NSMutableArray array]; int responding = 0, failed = 0;
            for (auto const& tracker : trackers) {
                bool good = false, pending = false, failure = false; int failures = 0;
                auto errors = [NSMutableArray array];
                for (auto const& endpoint : tracker.endpoints) {
                    if (!endpoint.enabled) continue;
                    for (auto protocol : {lt::protocol_version::V1, lt::protocol_version::V2}) {
                        if (!s.info_hashes.has(protocol)) continue;
                        auto const& announce = endpoint.info_hashes[protocol];
                        good = good || (announce.start_sent && !announce.last_error);
                        pending = pending || announce.updating; failures += announce.fails;
                        if (announce.last_error) {
                            failure = true; NSString* error = ns(announce.last_error.message());
                            if (![errors containsObject:error]) [errors addObject:error];
                        }
                    }
                }
                if (good) ++responding; else if (failure) ++failed;
                NSURL* url = [NSURL URLWithString:ns(tracker.url)];
                [announces addObject:@{@"host":url.host ?: @"", @"protocol":url.scheme ?: @"",
                    @"responding":@(good), @"pending":@(pending), @"failures":@(failures), @"errors":errors}];
            }
            auto failures = [NSMutableDictionary dictionary];
            for (auto const& [error, count] : j->peerFailures) failures[ns(error)] = @(count);
            bool checking = j->handle.is_valid() && (s.state == lt::torrent_status::checking_files || s.state == lt::torrent_status::checking_resume_data);
            [rows addObject:@{@"gid":ns(id), @"paused":@(j->paused), @"checking":@(checking),
                @"connections":@(s.num_connections), @"handshaked":@(connected), @"seeders":@(s.num_seeds),
                @"knownPeers":@(s.list_peers), @"downloadSpeed":@(s.download_payload_rate), @"uploadSpeed":@(s.upload_payload_rate),
                @"trackerCount":@(trackers.size()), @"trackersResponding":@(responding), @"trackersFailed":@(failed),
                @"trackers":announces, @"lastPeerError":ns(j->lastPeerError), @"peerFailures":failures}];
        }
        return @{@"dht":dht, @"jobs":rows};
    }
    id release(Job& j, id requested, std::string const& root) {
        if (![requested isKindOfClass:NSArray.class] || [requested count] > 128 || j.root != fs::path(root).lexically_normal())
            throw std::runtime_error("Invalid torrent cleanup request.");
        if (!j.handle.is_valid() || !j.ti) return @[];
        auto stateNow = j.handle.status();
        if (stateNow.state == lt::torrent_status::checking_files || stateNow.state == lt::torrent_status::checking_resume_data) return @[];
        progress(j); auto const& f = j.ti->files(); std::set<int> wanted;
        for (id v in requested) {
            if (![v isKindOfClass:NSNumber.class]) throw std::runtime_error("Invalid file index.");
            int n = [v intValue] - 1; if (n < 0 || n >= f.num_files()) throw std::runtime_error("Invalid file index."); wanted.insert(n);
        }
        // Downloading pieces cannot be reclaimed. The verified-file ledger keeps
        // an intact neighbor upload-ready after its shared piece is withdrawn.
        std::vector<lt::partial_piece_info> queue; j.handle.get_download_queue(queue);
        std::set<int> busy; for (auto const& p : queue) busy.insert(int(p.piece_index));
        std::set<int> accepted, pieceSet;
        auto priorities = piecePriorities(j);
        for (int n : wanted) {
            auto i = lt::file_index_t(n); auto length = f.file_size(i);
            bool padding = f.pad_file_at(i);
            if (!padding && j.selected.count(n) && !j.complete.count(n)) continue;
            int first = int(f.file_offset(i) / j.ti->piece_length());
            int last = length ? int((f.file_offset(i) + length - 1) / j.ti->piece_length()) : first - 1;
            bool safe = true;
            for (int p = first; !padding && p <= last; ++p) {
                if (busy.count(p) || priorities[size_t(p)] != lt::dont_download) { safe = false; break; }
            }
            if (!safe) continue;
            struct stat file{}; fileStat(j.root, f.file_path(i), file);
            accepted.insert(n); for (int p = first; !padding && p <= last; ++p) if (j.handle.have_piece(lt::piece_index_t(p))) pieceSet.insert(p);
        }
        if (accepted.empty()) return @[];
        // Finish any outstanding checkpoint before invalidating its piece map.
        if (j.saving) wait([&] { return !j.saving; });
        std::vector<lt::piece_index_t> pieces; for (int p : pieceSet) pieces.emplace_back(p);
        if (!j.handle.forget_verified_pieces(pieces)) return @[];
        j.released.insert(accepted.begin(), accepted.end());
        for (int i : accepted) if (!j.selected.count(i)) j.complete.erase(i);
        prioritize(j);
        auto before = j.flushed; j.handle.flush_cache(); wait([&] { return j.flushed != before; });
        auto result = [NSMutableArray array];
        for (int n : accepted) {
            if (removeFile(j.root, f.file_path(lt::file_index_t(n)))) [result addObject:@(n + 1)];
        }
        save(j, true); return result;
    }
    void change(Job& j, Options const& options) {
        auto next = j.options; for (auto const& [k,v] : options) next[k] = v;
        auto root = options.count("dir") ? rootPath(options.at("dir")) : j.root;
        if (j.started && root != j.root) throw std::runtime_error("Pause and choose a new download before changing its folder.");
        auto chosen = j.ti ? selection(next["select-file"], j.ti->num_files()) : std::set<int>{};
        bool selectionChanged = chosen != j.selected;
        for (int i : chosen) if (!j.selected.count(i) && j.released.erase(i)) j.complete.erase(i);
        j.root = root; j.options = std::move(next); j.selected = std::move(chosen);
        j.relay = integer(j.options["seed-time"]) > 0;
        if (selectionChanged) { j.finished = false; prioritize(j); }
        if (j.handle.is_valid() && options.count("max-upload-limit")) j.handle.set_upload_limit(integer(options.at("max-upload-limit")));
    }
    id rpc(std::string const& method, NSArray* args) {
        auto arg = [&](NSUInteger i) -> id { if (i >= args.count) throw std::runtime_error("Missing RPC argument."); return args[i]; };
        if (method == "getVersion") return @{@"version":@LIBTORRENT_VERSION, @"engine":@"libtorrent", @"enabledFeatures":@[@"BitTorrent", @"TCP", @"uTP", @"VerifiedResume", @"LiveRelease"]};
        if (method == "getNetworkDiagnostics") return networkDiagnostics();
        if (method == "getGlobalOption") { auto d = dictionary(config); [d removeObjectForKey:@"rpc-secret"]; return d; }
        if (method == "changeGlobalOption") {
            auto o = options(arg(0)); lt::settings_pack s;
            for (auto const& [k,v] : o) {
                if (k == "max-overall-upload-limit") s.set_int(lt::settings_pack::upload_rate_limit, integer(v));
                else if (k == "max-overall-download-limit") s.set_int(lt::settings_pack::download_rate_limit, integer(v));
                else throw std::runtime_error("Unsupported global option.");
            }
            session->apply_settings(s); for (auto const& [k,v] : o) config[k] = v; return @"OK";
        }
        if (method == "tellActive") {
            auto a = [NSMutableArray array]; for (auto& [id, j] : jobs) if (!j->paused && !j->finished) [a addObject:status(*j, args.count ? args[0] : nil)]; return a;
        }
        if (method == "addTorrent" || method == "addUri") {
            auto j = std::make_unique<Job>(); j->gid = str([[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:16]);
            std::transform(j->gid.begin(), j->gid.end(), j->gid.begin(), ::tolower);
            if (method == "addTorrent") {
                auto encoded = str(arg(0)); if (encoded.size() > 45 * 1024 * 1024) throw std::runtime_error("Torrent metadata is too large.");
                auto b = bytes([[NSData alloc] initWithBase64EncodedString:ns(encoded) options:0]);
                if (b.empty() || b.size() > 32 * 1024 * 1024) throw std::runtime_error("Invalid torrent metadata.");
                lt::error_code e; j->ti = std::make_shared<lt::torrent_info>(b.data(), int(b.size()), e);
                if (e) throw std::runtime_error("Invalid torrent metadata.");
                j->options = args.count > 2 ? options(args[2]) : Options{};
            } else {
                id uris = arg(0); if (![uris isKindOfClass:NSArray.class] || [uris count] != 1) throw std::runtime_error("Expected one magnet link.");
                lt::error_code e; j->magnet = lt::parse_magnet_uri(str(uris[0]), e);
                if (e) throw std::runtime_error("Invalid magnet link.");
                j->options = args.count > 1 ? options(args[1]) : Options{}; j->metadataOnly = true;
            }
            j->root = rootPath(j->options.count("dir") ? j->options["dir"] : config.at("dir"));
            if (j->ti) { validate(*j); j->selected = selection(j->options["select-file"], j->ti->num_files()); }
            j->relay = integer(j->options["seed-time"]) > 0;
            auto id = j->gid; jobs.emplace(id, std::move(j));
            if (!enabled(job(id).options, "pause", false)) { try { start(job(id)); } catch (...) { jobs.erase(id); throw; } }
            return ns(id);
        }
        if (method == "shutdown" || method == "forceShutdown") { stopping = 1; return @"OK"; }
        Job& j = job(str(arg(0)));
        if (method == "tellStatus") return status(j, args.count > 1 ? args[1] : nil);
        if (method == "getFiles") return files(j);
        if (method == "getPeers") return peers(j);
        if (method == "getOption") return dictionary(j.options);
        if (method == "changeOption") { change(j, options(arg(1))); return @"OK"; }
        if (method == "unpause") { start(j); return ns(j.gid); }
        if (method == "pause" || method == "forcePause") { pause(j); return ns(j.gid); }
        if (method == "releaseFiles") return release(j, arg(1), str(arg(2)));
        if (method == "addPeers") {
            if (!j.handle.is_valid() || (j.ti && j.ti->priv())) throw std::runtime_error("Peer hints are unavailable for this torrent.");
            id values = arg(1); if (![values isKindOfClass:NSArray.class] || [values count] > 64) throw std::runtime_error("Invalid peer list.");
            std::set<lt::tcp::endpoint> endpoints;
            for (id v in values) {
                if (![v isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid peer endpoint.");
                auto host = str(v[@"ip"]); auto port = integer([v[@"port"] isKindOfClass:NSNumber.class] ? std::to_string([v[@"port"] intValue]) : str(v[@"port"])); lt::error_code e;
                auto address = lt::make_address(host, e);
                if (e || address.is_unspecified() || address.is_multicast() || port < 1 || port > 65535) throw std::runtime_error("Invalid peer endpoint.");
                endpoints.emplace(address, uint16_t(port));
            }
            // libtorrent writes a peer off after three failed dials and revives it
            // only when a tracker lists it again (peer_list::update_peer). Hints are
            // the app's cached peers that completed a handshake with this Mac, firmer
            // evidence than a tracker listing, so each one earns that same retry.
            for (auto const& ep : endpoints) j.handle.connect_peer(ep, lt::peer_info::tracker);
            return @(endpoints.size());
        }
        if (method == "forceRemove" || method == "remove" || method == "removeDownloadResult") {
            pause(j); auto id = j.gid;
            if (j.handle.is_valid()) session->remove_torrent(j.handle);
            jobs.erase(id); return method == "removeDownloadResult" ? @"OK" : ns(id);
        }
        throw std::runtime_error("Unsupported torrent RPC method.");
    }
    void tick() {
        alerts();
        if (dhtRequested == Clock::time_point::min() || Clock::now() - dhtRequested > std::chrono::seconds(30)) {
            session->post_dht_stats(); dhtRequested = Clock::now();
        }
        // Explicit pause, cleanup and shutdown still checkpoint immediately.
        for (auto& [id, j] : jobs) if (!j->paused && !j->saving && Clock::now() - j->lastSaved > std::chrono::minutes(3)) save(*j, false);
        // Often enough to follow the files that are nearly done, rarely enough
        // that re-reading per-file progress stays off the transfer's back.
        for (auto& [id, j] : jobs) {
            if (Clock::now() - j->focused < std::chrono::seconds(20)) continue;
            j->focused = Clock::now();
            try { focus(*j); } catch (...) {}
        }
        if (Clock::now() - sessionSaved > std::chrono::minutes(2)) saveSession();
    }
    void saveSession() {
        try { atomicWrite(state / "libtorrent-dht.dat", lt::write_session_params_buf(session->session_state(lt::session_handle::save_dht_state), lt::session_handle::save_dht_state)); } catch (...) {}
        sessionSaved = Clock::now();
    }
    void shutdown() {
        for (auto& [id, j] : jobs) { try { pause(*j); } catch (...) {} }
        saveSession(); session.reset();
    }
};

static Bytes request(int fd) {
    std::string buffer; size_t split = std::string::npos, length = 0;
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (Clock::now() < deadline && !stopping) {
        pollfd p{fd, POLLIN, 0}; if (poll(&p, 1, 50) <= 0) continue;
        char chunk[65536]; auto n = recv(fd, chunk, sizeof(chunk), 0); if (n <= 0) break;
        buffer.append(chunk, size_t(n));
        if (split == std::string::npos) {
            split = buffer.find("\r\n\r\n");
            if (split == std::string::npos) { if (buffer.size() > 16384) break; continue; }
            if (split > 16384 || buffer.compare(0, 20, "POST /jsonrpc HTTP/1") != 0) break;
            auto headers = buffer.substr(0, split); std::transform(headers.begin(), headers.end(), headers.begin(), ::tolower);
            if (headers.find("\r\norigin:") != std::string::npos || headers.find("transfer-encoding:") != std::string::npos) break;
            auto start = headers.find("\r\ncontent-length:"); if (start == std::string::npos) break;
            auto end = headers.find("\r\n", start + 2); auto count = headers.substr(start + 17, end - start - 17);
            size_t consumed = 0; length = std::stoull(count, &consumed);
            if (count.find_first_not_of(" \t", consumed) != std::string::npos || length > 64 * 1024 * 1024) break;
            split += 4;
        }
        if (buffer.size() >= split + length) return Bytes(buffer.begin() + split, buffer.begin() + split + length);
    }
    throw std::runtime_error("Invalid local RPC request.");
}
static void respond(int fd, id value) {
    auto b = json(value); std::string header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " + std::to_string(b.size()) + "\r\n\r\n";
    Bytes wire(header.begin(), header.end()); wire.insert(wire.end(), b.begin(), b.end()); size_t offset = 0;
    timeval timeout{2, 0}; setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    while (offset < wire.size()) { auto n = send(fd, wire.data() + offset, wire.size() - offset, 0); if (n <= 0) break; offset += size_t(n); }
}
int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc == 2 && std::string(argv[1]) == "--version") {
            std::cout << "MyCloudDriver libtorrent " LIBTORRENT_VERSION " TCP uTP VerifiedResume LiveRelease\n"; return 0;
        }
        signal(SIGINT, stopSignal); signal(SIGTERM, stopSignal); signal(SIGPIPE, SIG_IGN); umask(0077);
        try {
            if (argc != 2 || std::string(argv[1]).find("--conf-path=") != 0) throw std::runtime_error("Expected a private runtime configuration.");
            fs::path file(std::string(argv[1]).substr(12)); auto b = readFile(file, 1024 * 1024);
            std::istringstream stream(std::string(b.begin(), b.end())); Options config; std::string line;
            while (std::getline(stream, line)) { auto pos = line.find('='); if (pos != std::string::npos && !line.empty() && line[0] != '#') config[line.substr(0, pos)] = line.substr(pos + 1); }
            auto token = "token:" + config["rpc-secret"]; int port = integer(config["rpc-listen-port"]);
            if (token.size() < 22 || port < 1024 || port > 65535) throw std::runtime_error("Private RPC configuration is missing.");
            int parent = integer(config["stop-with-process"]); auto state = file.parent_path(); privateDirectory(state);
            int server = socket(AF_INET, SOCK_STREAM, 0); if (server < 0) throw std::runtime_error("Cannot create local RPC socket.");
            int reuse = 1; setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
            sockaddr_in address{}; address.sin_len = sizeof(address); address.sin_family = AF_INET;
            address.sin_port = htons(uint16_t(port)); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(server, 16)) throw std::runtime_error("Cannot open local RPC port.");
            Engine engine(config, state);
            while (!stopping && (!parent || kill(parent, 0) == 0 || errno == EPERM)) {
                @autoreleasepool {
                    engine.tick(); pollfd p{server, POLLIN, 0}; if (poll(&p, 1, 500) <= 0) continue;
                    int client = accept(server, nullptr, nullptr); if (client < 0) continue;
                    id identifier = NSNull.null;
                    @try {
                        try {
                            id message = parse(request(client));
                            if (![message isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid JSON RPC.");
                            identifier = message[@"id"] ?: NSNull.null;
                            id params = message[@"params"];
                            if (![params isKindOfClass:NSArray.class] || ![params count] || ![params[0] isKindOfClass:NSString.class]
                                || str(params[0]) != token) throw std::runtime_error("Unauthorized local RPC.");
                            auto method = str(message[@"method"]); if (method.find("aria2.") != 0) throw std::runtime_error("Invalid RPC method.");
                            id result = engine.rpc(method.substr(6), [params subarrayWithRange:NSMakeRange(1, [params count] - 1)]);
                            respond(client, @{@"jsonrpc":@"2.0", @"id":identifier, @"result":result});
                        } catch (std::exception const& error) {
                            respond(client, @{@"jsonrpc":@"2.0", @"id":identifier, @"error":@{@"code":@1, @"message":ns(error.what()) ?: @"Torrent request failed."}});
                        }
                    } @catch (NSException*) {
                        respond(client, @{@"jsonrpc":@"2.0", @"id":identifier, @"error":@{@"code":@1, @"message":@"Invalid torrent request."}});
                    }
                    close(client);
                }
            }
            close(server); engine.shutdown(); return 0;
        } catch (std::exception const& error) { std::cerr << error.what() << '\n'; return 1; }
    }
}
