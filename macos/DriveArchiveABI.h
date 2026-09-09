#pragma once
#include <sys/types.h>
#include <stdint.h>

// macOS exports libarchive.2 but recent Command Line Tools omit its headers.
// This is the small public C ABI used by our reader (no private Apple APIs).
// Reference: https://github.com/libarchive/libarchive/blob/master/libarchive/archive.h
struct archive;
struct archive_entry;
typedef ssize_t la_ssize_t;
enum { ARCHIVE_EOF = 1, ARCHIVE_OK = 0, ARCHIVE_WARN = -20 };
enum { AE_IFDIR = 0040000, AE_IFREG = 0100000 };
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *reader);
extern int archive_read_support_format_all(struct archive *reader);
extern int archive_read_add_passphrase(struct archive *reader, const char *password);
extern int archive_read_open_filename(struct archive *reader, const char *path, size_t block_size);
extern int archive_read_next_header(struct archive *reader, struct archive_entry **entry);
extern la_ssize_t archive_read_data(struct archive *reader, void *buffer, size_t capacity);
extern int archive_read_free(struct archive *reader);
extern int64_t archive_filter_bytes(struct archive *reader, int filter);
extern const char *archive_error_string(struct archive *reader);
extern const char *archive_entry_pathname(struct archive_entry *entry);
extern const char *archive_entry_symlink(struct archive_entry *entry);
extern const char *archive_entry_hardlink(struct archive_entry *entry);
extern mode_t archive_entry_filetype(struct archive_entry *entry);
