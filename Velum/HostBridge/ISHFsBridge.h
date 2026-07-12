//
//  ISHFsBridge.h
//  Velum
//
//  Phase 3.3: Obj-C facade for iSH fakefs operations.
//
//  Wraps iSH internal C APIs (generic_open / generic_statat / dir->ops->readdir /
//  fd->ops->read|write|lseek) so Swift can read/write the guest fakefs without
//  going through DebugServer's HTTP/JSON-RPC channel.
//
//  Implementation mirrors DebugServer.c's handle_fs_* handlers, minus the HTTP
//  envelope and base64 encoding — returns native NSData/NSArray/NSDictionary.
//
//  Thread-safety: all methods borrow PID 1 as the `current` task context (same
//  trick DebugServer uses) and are serialized on a private serial queue.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A single directory entry from `listDir:`.
@interface ISHDirEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint64_t inode;
@property (nonatomic) uint64_t size;
@property (nonatomic) mode_t mode;       // st_mode (bits: S_IFMT, permission bits)
@property (nonatomic) time_t mtime;
@end

/// File stat info from `statPath:`.
@interface ISHFileStat : NSObject
@property (nonatomic) uint64_t size;
@property (nonatomic) mode_t mode;
@property (nonatomic) uid_t uid;
@property (nonatomic) gid_t gid;
@property (nonatomic) uint64_t inode;
@property (nonatomic) uint64_t nlink;
@property (nonatomic) time_t mtime;
@end

/// Error codes from ISHFsBridge. Used as `NSError.code` under domain `ISHFsBridge`.
typedef NS_ENUM(NSInteger, ISHFsError) {
    ISHFsErrorUnknown          = -1,
    ISHFsErrorNotFound         = -2,
    ISHFsErrorNotADirectory    = -3,
    ISHFsErrorPermissionDenied = -4,
    ISHFsErrorIO               = -5,
};

@interface ISHFsBridge : NSObject

+ (instancetype)sharedInstance;

/// List directory entries. Returns nil and sets error on failure.
- (nullable NSArray<ISHDirEntry *> *)listDir:(NSString *)path
                                       error:(NSError *_Nullable *_Nullable)error;

/// Stat a path. Returns nil and sets error on failure.
- (nullable ISHFileStat *)statPath:(NSString *)path
                             error:(NSError *_Nullable *_Nullable)error;

/// Check if path exists.
- (BOOL)exists:(NSString *)path;

/// Read up to `length` bytes from `path` starting at `offset`.
- (nullable NSData *)readFile:(NSString *)path
                       offset:(off_t)offset
                       length:(size_t)length
                        error:(NSError *_Nullable *_Nullable)error;

/// Write data to `path` (truncates if exists, creates if not, mode 0755).
- (NSInteger)writeFile:(NSString *)path
                  data:(NSData *)data
                 error:(NSError *_Nullable *_Nullable)error;

/// Read symlink target. Returns nil if path is not a symlink (or on error).
- (nullable NSString *)readlinkPath:(NSString *)path
                              error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
