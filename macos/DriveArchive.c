#include "DriveArchiveABI.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/statvfs.h>

static uint64_t available_bytes(int directory) {
    struct statvfs info;
    if (fstatvfs(directory, &info)) return 0;
    uint64_t block = info.f_frsize ? info.f_frsize : info.f_bsize;
    if (!block) return 0;
    return info.f_bavail > UINT64_MAX / block ? UINT64_MAX : info.f_bavail * block;
}

// Extract into a new, private directory. Every component is opened relative to
// its directory descriptor; links, absolute paths and traversal are rejected.
static int parent_fd(int root, char *path, char **leaf) {
    if (!path[0] || path[0] == '/') { errno = EINVAL; return -1; }
    int fd = dup(root);
    char *part = path, *slash;
    while ((slash = strchr(part, '/'))) {
        *slash = 0;
        if (*part && strcmp(part, ".")) {
            if (!strcmp(part, "..")) { close(fd); errno = EINVAL; return -1; }
            if (mkdirat(fd, part, 0700) && errno != EEXIST) { close(fd); return -1; }
            int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            close(fd); if (next < 0) return -1; fd = next;
        }
        part = slash + 1;
    }
    if (!*part || !strcmp(part, ".") || !strcmp(part, "..")) { close(fd); errno = EINVAL; return -1; }
    *leaf = part; return fd;
}

int mcd_archive_extract(const char *source, const char *destination, const char *password,
                        void *context, int (*progress)(void *, long long, const char *),
                        char *error, size_t error_size) {
    return mcd_archive_extract_limited(source, destination, password, UINT64_C(64) << 30, 100000,
                                      context, progress, error, error_size);
}

int mcd_archive_extract_limited(const char *source, const char *destination, const char *password,
                        uint64_t maximum_bytes, uint64_t maximum_entries,
                        void *context, mcd_archive_progress progress, char *error, size_t error_size) {
    if (!maximum_bytes || !maximum_entries || !progress) {
        snprintf(error, error_size, "Archive extraction limits are invalid."); return 4;
    }
    struct archive *reader = archive_read_new();
    if (!reader) { snprintf(error, error_size, "Could not create archive reader."); return 1; }
    archive_read_support_filter_all(reader); archive_read_support_format_all(reader);
    if (password && *password) archive_read_add_passphrase(reader, password);
    int root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW), result = 0;
    if (root < 0) { snprintf(error, error_size, "The extraction folder is unavailable."); result = 1; goto finish; }
    uint64_t free_bytes = available_bytes(root), expanded = 0, entries = 0;
    uint64_t reserve = free_bytes / 20;
    if (reserve > (UINT64_C(1) << 30)) reserve = UINT64_C(1) << 30;
    if (maximum_bytes > free_bytes - reserve) maximum_bytes = free_bytes - reserve;
    if (archive_read_open_filename(reader, source, 1024 * 1024) != ARCHIVE_OK) goto archive_error;
    struct archive_entry *entry;
    int status;
    while ((status = archive_read_next_header(reader, &entry)) != ARCHIVE_EOF) {
        if (status < ARCHIVE_WARN) goto archive_error;
        if (++entries > maximum_entries) { snprintf(error, error_size, "The archive contains too many entries to extract safely."); result = 4; goto finish; }
        if (progress(context, archive_filter_bytes(reader, -1), archive_entry_pathname(entry))) { result = 3; goto finish; }
        const char *raw = archive_entry_pathname(entry);
        if (!raw || strnlen(raw, PATH_MAX + 1) > PATH_MAX || archive_entry_symlink(entry) || archive_entry_hardlink(entry)) {
            snprintf(error, error_size, "The archive contains a link or an invalid path."); result = 1; goto finish;
        }
        mode_t type = archive_entry_filetype(entry);
        if (type != AE_IFDIR && type != AE_IFREG) {
            snprintf(error, error_size, "The archive contains an unsupported special file."); result = 1; goto finish;
        }
        int64_t entry_size = archive_entry_size(entry);
        if (type == AE_IFREG && entry_size > 0 && (uint64_t)entry_size > maximum_bytes - expanded) {
            snprintf(error, error_size, "The expanded archive exceeds the extraction allowance or available disk space."); result = 4; goto finish;
        }
        char *path = strdup(raw), *leaf;
        if (!path) { result = 1; goto finish; }
        size_t length = strlen(path);
        while (length && path[length - 1] == '/') path[--length] = 0;
        if (type == AE_IFDIR && (!strcmp(path, ".") || !strcmp(path, "./"))) { free(path); continue; }
        int parent = parent_fd(root, path, &leaf);
        if (parent < 0) { free(path); snprintf(error, error_size, "An archive path is unsafe or inaccessible."); result = 1; goto finish; }
        if (type == AE_IFDIR) {
            if (mkdirat(parent, leaf, 0700) && errno != EEXIST) result = 1;
            int check = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (check < 0) result = 1; else close(check);
        } else {
            int file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (file < 0) result = 1;
            else {
                char buffer[256 * 1024]; la_ssize_t count;
                while ((count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
                    uint64_t available = available_bytes(root);
                    if ((uint64_t)count > maximum_bytes - expanded || available < reserve || (uint64_t)count > available - reserve) {
                        snprintf(error, error_size, "The expanded archive exceeds the extraction allowance or available disk space."); result = 4; break;
                    }
                    expanded += (uint64_t)count;
                    la_ssize_t offset = 0;
                    while (offset < count) {
                        ssize_t written = write(file, buffer + offset, (size_t)(count - offset));
                        if (written < 0 && errno == EINTR) continue;
                        if (written <= 0) { result = 1; break; }
                        offset += written;
                    }
                    if (result || progress(context, archive_filter_bytes(reader, -1), raw)) { if (!result) result = 3; break; }
                }
                close(file);
                if (count < 0 && !result) { close(parent); free(path); goto archive_error; }
            }
        }
        close(parent); free(path);
        if (result) { if (result == 1) snprintf(error, error_size, "Could not write an extracted file; check space and duplicate names."); goto finish; }
    }
    goto finish;
archive_error: {
    const char *message = archive_error_string(reader);
    snprintf(error, error_size, "%s", message ? message : "Could not read this archive.");
    result = message && !strcasestr(message, "unsupported") && !strcasestr(message, "not supported") &&
        (strcasestr(message, "passphrase") || strcasestr(message, "password")) ? 2 : 1;
}
finish:
    if (root >= 0) close(root);
    archive_read_free(reader);
    return result;
}
