//
//  ISHFsBridge.m
//  Velum
//
//  Phase 3.3: Implementation of ISHFsBridge — direct calls into iSH fakefs.
//
//  Mirrors DebugServer.c's handle_fs_* handlers, minus the HTTP envelope and
//  base64 encoding. Returns native NSData / NSArray / ISHFileStat.
//
//  All methods run on a private serial queue (`fsQueue`) to guarantee
//  thread-affinity for `current` (the iSH thread-local task pointer).
//

#import "ISHFsBridge.h"

#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include "kernel/task.h"
#include "kernel/fs.h"
#include "kernel/init.h"
#include "kernel/calls.h"
#include "fs/fd.h"
#include "fs/stat.h"
#include "fs/path.h"

// Syscall constants from iSH (not exposed via a single header consistently).
#ifndef AT_PWD
#define AT_PWD (0)
#endif
#ifndef O_RDONLY_
#define O_RDONLY_ (0)
#endif
#ifndef O_WRONLY_
#define O_WRONLY_ (1)
#endif
#ifndef O_CREAT_
#define O_CREAT_ (0100)
#endif
#ifndef O_TRUNC_
#define O_TRUNC_ (01000)
#endif
#ifndef O_DIRECTORY_
#define O_DIRECTORY_ (0200000)
#endif
#ifndef LSEEK_SET
#define LSEEK_SET (0)
#endif

static NSString *const ISHFsErrorDomain = @"ISHFsBridge";

@implementation ISHDirEntry
@end

@implementation ISHFileStat
@end

@implementation ISHFsBridge {
    dispatch_queue_t _fsQueue;
}

+ (instancetype)sharedInstance {
    static ISHFsBridge *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fsQueue = dispatch_queue_create("app.velum.ishfs", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// MARK: - Context helper

/// Borrow PID 1's `current` for fs operations. Same trick DebugServer.c uses.
/// MUST be called on `_fsQueue` to guarantee thread-affinity.
static void ensure_current(void) {
    if (current != NULL) return;
    lock(&pids_lock);
    struct task *init = pid_get_task(1);
    unlock(&pids_lock);
    if (init) current = init;
}

// MARK: - Error helper

static NSError *makeError(ISHFsError code, NSString *msg) {
    return [NSError errorWithDomain:ISHFsErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"unknown fs error"}];
}

static NSError *errorFromErrno(const char *path, int err) {
    NSString *msg = [NSString stringWithFormat:@"%@: iSH error %d", @(path), err];
    // iSH uses negative errno values. Map common ones by magnitude.
    ISHFsError code = ISHFsErrorUnknown;
    if (err == -2)      code = ISHFsErrorNotFound;        // ENOENT
    else if (err == -20) code = ISHFsErrorNotADirectory;   // ENOTDIR
    else if (err == -13) code = ISHFsErrorPermissionDenied;// EACCES
    else if (err == -5)  code = ISHFsErrorIO;              // EIO
    return makeError(code, msg);
}

// MARK: - listDir

- (nullable NSArray<ISHDirEntry *> *)listDir:(NSString *)path
                                       error:(NSError **)error {
    __block NSArray<ISHDirEntry *> *result = nil;
    __block NSError *blockError = nil;

    dispatch_sync(_fsQueue, ^{
        ensure_current();
        const char *cpath = path.fileSystemRepresentation;
        struct fd *dir = generic_open(cpath, O_RDONLY_ | O_DIRECTORY_, 0);
        if (IS_ERR(dir)) {
            blockError = errorFromErrno(cpath, (int)PTR_ERR(dir));
            return;
        }

        NSMutableArray<ISHDirEntry *> *entries = [NSMutableArray array];
        struct dir_entry entry;
        int count = 0;
        while (dir->ops->readdir && dir->ops->readdir(dir, &entry) == 1) {
            ISHDirEntry *e = [ISHDirEntry new];
            e.name = @(entry.name);
            e.inode = entry.inode;

            // Stat each entry for size/mode (best-effort — ignore per-entry errors).
            struct statbuf st;
            char full[MAX_PATH];
            snprintf(full, sizeof(full), "%s/%s", cpath, entry.name);
            if (generic_statat(AT_PWD, full, &st, true) == 0) {
                e.size = st.size;
                e.mode = st.mode;
                e.mtime = st.mtime;
            }
            [entries addObject:e];
            if (++count >= 10000) break;
        }
        fd_close(dir);
        result = entries;
    });

    if (error) *error = blockError;
    return result;
}

// MARK: - statPath

- (nullable ISHFileStat *)statPath:(NSString *)path
                             error:(NSError **)error {
    __block ISHFileStat *result = nil;
    __block NSError *blockError = nil;

    dispatch_sync(_fsQueue, ^{
        ensure_current();
        const char *cpath = path.fileSystemRepresentation;
        struct statbuf st;
        int err = generic_statat(AT_PWD, cpath, &st, true);
        if (err < 0) {
            blockError = errorFromErrno(cpath, err);
            return;
        }
        ISHFileStat *s = [ISHFileStat new];
        s.size = st.size;
        s.mode = st.mode;
        s.uid = st.uid;
        s.gid = st.gid;
        s.inode = st.inode;
        s.nlink = st.nlink;
        s.mtime = st.mtime;
        result = s;
    });

    if (error) *error = blockError;
    return result;
}

// MARK: - exists

- (BOOL)exists:(NSString *)path {
    __block BOOL result = NO;
    dispatch_sync(_fsQueue, ^{
        ensure_current();
        struct statbuf st;
        int err = generic_statat(AT_PWD, path.fileSystemRepresentation, &st, true);
        result = (err == 0);
    });
    return result;
}

// MARK: - readFile

- (nullable NSData *)readFile:(NSString *)path
                       offset:(off_t)offset
                       length:(size_t)length
                        error:(NSError **)error {
    if (length == 0) length = 4096;
    if (length > 1024 * 1024) length = 1024 * 1024; // 1MB cap

    __block NSData *result = nil;
    __block NSError *blockError = nil;

    dispatch_sync(_fsQueue, ^{
        ensure_current();
        const char *cpath = path.fileSystemRepresentation;
        struct fd *fd = generic_open(cpath, O_RDONLY_, 0);
        if (IS_ERR(fd)) {
            blockError = errorFromErrno(cpath, (int)PTR_ERR(fd));
            return;
        }

        if (offset > 0 && fd->ops->lseek) {
            fd->ops->lseek(fd, offset, LSEEK_SET);
        }

        uint8_t *buf = malloc(length);
        ssize_t nread = 0;
        if (fd->ops->read) {
            nread = fd->ops->read(fd, buf, length);
        }
        fd_close(fd);

        if (nread < 0) {
            free(buf);
            blockError = errorFromErrno(cpath, (int)nread);
            return;
        }
        result = [NSData dataWithBytesNoCopy:buf length:(size_t)nread freeWhenDone:YES];
    });

    if (error) *error = blockError;
    return result;
}

// MARK: - writeFile

- (NSInteger)writeFile:(NSString *)path
                  data:(NSData *)data
                 error:(NSError **)error {
    __block NSInteger written = 0;
    __block NSError *blockError = nil;

    dispatch_sync(_fsQueue, ^{
        ensure_current();
        const char *cpath = path.fileSystemRepresentation;
        struct fd *fd = generic_open(cpath, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0755);
        if (IS_ERR(fd)) {
            blockError = errorFromErrno(cpath, (int)PTR_ERR(fd));
            return;
        }

        ssize_t n = 0;
        if (fd->ops->write) {
            n = fd->ops->write(fd, data.bytes, data.length);
        }
        fd_close(fd);

        if (n < 0) {
            blockError = errorFromErrno(cpath, (int)n);
            return;
        }
        written = (NSInteger)n;
    });

    if (error) *error = blockError;
    return written;
}

// MARK: - readlink

- (nullable NSString *)readlinkPath:(NSString *)path
                              error:(NSError **)error {
    __block NSString *result = nil;
    __block NSError *blockError = nil;

    dispatch_sync(_fsQueue, ^{
        ensure_current();
        const char *cpath = path.fileSystemRepresentation;
        char target[MAX_PATH];
        ssize_t n = generic_readlinkat(AT_PWD, cpath, target, sizeof(target) - 1);
        if (n < 0) {
            blockError = errorFromErrno(cpath, (int)n);
            return;
        }
        target[n] = '\0';
        result = @(target);
    });

    if (error) *error = blockError;
    return result;
}

@end
