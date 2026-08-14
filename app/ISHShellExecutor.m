//
//  ISHShellExecutor.m
//  iSH
//
//  Shell execution implementation with line-by-line output and process completion
//

#import "ISHShellExecutor.h"
#import "AppDelegate.h"
#import "LinuxInterop.h"

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "fs/devices.h"
#include "fs/real.h"

#pragma mark - Result Implementation

@interface ISHShellExecutionResult ()
@property (nonatomic, readwrite) int exitCode;
@property (nonatomic, readwrite) int pid;
@property (nonatomic, readwrite) ISHShellExecutorError error;
@property (nonatomic, readwrite, copy) NSString *output;
@property (nonatomic, readwrite, copy) NSString *errorOutput;
@property (nonatomic, readwrite) NSTimeInterval duration;
@end

@implementation ISHShellExecutionResult
@end

#pragma mark - Execution Context

@interface ISHShellExecutionContext : NSObject {
    int _stdoutPipe[2];
    int _stderrPipe[2];
}
@property (nonatomic) int guestPid;
@property (nonatomic) NSDate *startTime;
@property (nonatomic, copy) ISHShellLineCallback lineCallback;
@property (nonatomic, copy) ISHShellCompletionCallback completion;
@property (nonatomic) NSMutableString *stdoutBuffer;
@property (nonatomic) NSMutableString *stderrBuffer;
@property (nonatomic) dispatch_semaphore_t waitSemaphore;
@property (nonatomic) ISHShellExecutionResult *result;
@property (atomic) BOOL isCompleted;
/// 输出被截断标记（超过 ISH_MAX_CAPTURE_BYTES）。
@property (atomic) BOOL outputTruncated;

// [P0-7] 退出与收尾状态机（统一在 @synchronized(ctx) 下推进，杜绝尾部丢失与并发拷贝崩溃）
@property (nonatomic) BOOL exitReceived;
@property (nonatomic) int pendingExitCode;
@property (nonatomic) int readersFinished;
@property (nonatomic) BOOL finalized;

// [性能] 行输出批量派发: 每行 dispatch 主队列在长输出时会洪泛主线程(卡 UI),
// 改为攒批 + 单次 drain。
@property (nonatomic) NSMutableArray<NSArray *> *pendingLines;
@property (nonatomic) BOOL drainScheduled;

- (void)enqueueLine:(NSString *)line isStdErr:(BOOL)isStdErr;
- (void)drainPendingLines;
- (void)maybeFinalize;
- (int *)stdoutPipe;
- (int *)stderrPipe;

@end

@implementation ISHShellExecutionContext

- (int *)stdoutPipe {
    return _stdoutPipe;
}

- (int *)stderrPipe {
    return _stderrPipe;
}

- (instancetype)init {
    if (self = [super init]) {
        _stdoutBuffer = [NSMutableString string];
        _stderrBuffer = [NSMutableString string];
        _stdoutPipe[0] = -1;
        _stdoutPipe[1] = -1;
        _stderrPipe[0] = -1;
        _stderrPipe[1] = -1;
        _result = [[ISHShellExecutionResult alloc] init];
        _result.error = ISHShellExecutorErrorNone;
        _pendingLines = [NSMutableArray array];
    }
    return self;
}

/// 把一行输出放进批量缓冲, 首次时调度一次主队列 drain。
- (void)enqueueLine:(NSString *)line isStdErr:(BOOL)isStdErr {
    if (self.lineCallback == NULL) return;
    @synchronized(self.pendingLines) {
        [self.pendingLines addObject:isStdErr ? @[line, @(YES)] : @[line, @(NO)]];
        if (self.drainScheduled) return;
        self.drainScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self drainPendingLines];
        });
    }
}

/// 主队列上一次性派发当前攒下的所有行。
- (void)drainPendingLines {
    NSArray<NSArray *> *batch = nil;
    @synchronized(self.pendingLines) {
        self.drainScheduled = NO;
        if (self.pendingLines.count > 0) {
            batch = [self.pendingLines copy];
            [self.pendingLines removeAllObjects];
        }
    }
    if (batch == nil) return;
    ISHShellLineCallback cb = self.lineCallback;
    if (cb == NULL) return;
    for (NSArray *pair in batch) {
        cb(pair[0], [pair[1] boolValue]);
    }
}

- (void)cleanup {
    if (_stdoutPipe[0] >= 0) close(_stdoutPipe[0]);
    if (_stdoutPipe[1] >= 0) close(_stdoutPipe[1]);
    if (_stderrPipe[0] >= 0) close(_stderrPipe[0]);
    if (_stderrPipe[1] >= 0) close(_stderrPipe[1]);
    _stdoutPipe[0] = _stdoutPipe[1] = -1;
    _stderrPipe[0] = _stderrPipe[1] = -1;
}

- (void)dealloc {
    [self cleanup];
}

/// 进程退出 + 两个 reader 都排空管道后, 一次性收尾:
/// 快照缓冲(与 append 同一把锁) → 关管道 → 回调 completion → 唤醒同步等待者。
- (void)maybeFinalize {
    @synchronized(self) {
        if (self.finalized || !self.exitReceived || self.readersFinished < 2)
            return;
        self.finalized = YES;
        self.result.exitCode = self.pendingExitCode;
        self.result.duration = -[self.startTime timeIntervalSinceNow];
        @synchronized(self.stdoutBuffer) {
            self.result.output = [self.stdoutBuffer copy];
        }
        @synchronized(self.stderrBuffer) {
            self.result.errorOutput = [self.stderrBuffer copy];
        }
        if (self.outputTruncated) {
            self.result.output = [self.result.output stringByAppendingString:@"\n…[output truncated]"];
        }
    }

    [self cleanup];

    if (self.completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.completion(self.result);
        });
    }
    if (self.waitSemaphore) {
        dispatch_semaphore_signal(self.waitSemaphore);
    }
}

@end

#pragma mark - Executor Implementation

// 单条命令输出缓冲上限(16MB): 超过后丢弃新增内容并打截断标记, 防止
// 长输出(如 cat /dev/zero)无限累积内存导致 jetsam。
#define ISH_MAX_CAPTURE_BYTES (16 * 1024 * 1024)

@implementation ISHShellExecutor

static NSMutableDictionary<NSNumber *, ISHShellExecutionContext *> *_activeExecutions;
static dispatch_queue_t _readerQueue;
static dispatch_once_t _onceToken;

+ (void)initialize {
    if (self == [ISHShellExecutor class]) {
        _activeExecutions = [NSMutableDictionary dictionary];
        dispatch_once(&_onceToken, ^{
            _readerQueue = dispatch_queue_create("com.ish.shellexecutor.reader",
                                                 DISPATCH_QUEUE_CONCURRENT);
        });

        // Register for process exit notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(processDidExit:)
                                                     name:ProcessExitedNotification
                                                   object:nil];
    }
}

#pragma mark - Public API

+ (int)executeCommand:(NSString *)command
         lineCallback:(ISHShellLineCallback)lineCallback
           completion:(ISHShellCompletionCallback)completion {
    return [self executeExecutable:@"/bin/sh"
                         arguments:@[@"-c", command]
                       environment:nil
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {

    ISHShellExecutionContext *ctx = [[ISHShellExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.completion = completion;
    ctx.startTime = [NSDate date];

    // Create pipes for stdout and stderr
    if (pipe([ctx stdoutPipe]) < 0 || pipe([ctx stderrPipe]) < 0) {
        NSLog(@"ISHShellExecutor: pipe() failed: %s", strerror(errno));
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    // Set read ends to non-blocking
    fcntl([ctx stdoutPipe][0], F_SETFL, O_NONBLOCK);
    fcntl([ctx stderrPipe][0], F_SETFL, O_NONBLOCK);

#if !ISH_LINUX
    struct task *saved_current = current;

    // Create new process
    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: become_new_init_child failed: %d", err);
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    struct task *task = current;

    // Setup stdin as /dev/null
    struct fd *stdin_fd = adhoc_fd_create(&realfs_fdops);
    if (stdin_fd) {
        stdin_fd->real_fd = open("/dev/null", O_RDONLY);
        task->files->files[0] = stdin_fd;
    }

    // Setup stdout to pipe
    struct fd *stdout_fd = adhoc_fd_create(&realfs_fdops);
    if (stdout_fd) {
        stdout_fd->real_fd = dup([ctx stdoutPipe][1]);
        task->files->files[1] = stdout_fd;
    }

    // Setup stderr to pipe
    struct fd *stderr_fd = adhoc_fd_create(&realfs_fdops);
    if (stderr_fd) {
        stderr_fd->real_fd = dup([ctx stderrPipe][1]);
        task->files->files[2] = stderr_fd;
    }

    // Close write ends in parent
    close([ctx stdoutPipe][1]);
    close([ctx stderrPipe][1]);
    [ctx stdoutPipe][1] = -1;
    [ctx stderrPipe][1] = -1;

    // Build argv (NUL-separated string)
    NSMutableArray<NSString *> *fullArgs = [NSMutableArray arrayWithObject:executable];
    if (arguments) {
        [fullArgs addObjectsFromArray:arguments];
    }

    char argv_buf[4096];
    size_t pos = 0;
    for (NSString *arg in fullArgs) {
        const char *str = arg.UTF8String;
        size_t len = strlen(str) + 1;
        if (pos + len + 1 >= sizeof(argv_buf)) {  // +1 for final NUL
            current = saved_current;
            [ctx cleanup];
            NSLog(@"ISHShellExecutor: argv too long");
            return ISHShellExecutorErrorExecFailed;
        }
        memcpy(argv_buf + pos, str, len);
        pos += len;
    }
    // Add final NUL terminator for double-NUL ending
    argv_buf[pos] = '\0';

    // Build envp
    NSMutableString *envp_str = [NSMutableString string];

    // Default environment
    [envp_str appendString:@"TERM=xterm-256color\0"];
    [envp_str appendString:@"HOME=/root\0"];
    [envp_str appendString:@"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"];
#if defined(GUEST_ARM64)
    [envp_str appendString:@"PYTHONMALLOC=malloc\0"];
#endif

    // Custom environment
    if (environment) {
        for (NSString *key in environment) {
            [envp_str appendFormat:@"%@=%@\0", key, environment[key]];
        }
    }

    // Add final NUL terminator for double-NUL ending
    [envp_str appendString:@"\0"];

    const char *envp = envp_str.UTF8String;

    // Execute
    err = do_execve(executable.UTF8String, fullArgs.count, argv_buf, envp);
    if (err < 0) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: do_execve failed: %d", err);
        return ISHShellExecutorErrorExecFailed;
    }

    // Get guest PID and start task
    ctx.guestPid = task->pid;
    ctx.result.pid = ctx.guestPid;
    task_start(task);
    current = saved_current;

    // Register context
    @synchronized(_activeExecutions) {
        _activeExecutions[@(ctx.guestPid)] = ctx;
    }

    // Start reader threads
    [self startReaderForPipe:[ctx stdoutPipe][0] context:ctx isStdErr:NO];
    [self startReaderForPipe:[ctx stderrPipe][0] context:ctx isStdErr:YES];

    return ctx.guestPid;
#else
    // TODO: Linux implementation using linux_start_session
    [ctx cleanup];
    return ISHShellExecutorErrorProcessCreationFailed;
#endif
}

+ (ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                        timeout:(NSTimeInterval)timeout
                                   lineCallback:(ISHShellLineCallback)lineCallback {

    ISHShellExecutionContext *ctx = [[ISHShellExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.waitSemaphore = dispatch_semaphore_create(0);
    ctx.startTime = [NSDate date];

    __block ISHShellExecutionResult *result = nil;

    int pid = [self executeCommand:command
                      lineCallback:lineCallback
                        completion:^(ISHShellExecutionResult *execResult) {
        result = execResult;
        dispatch_semaphore_signal(ctx.waitSemaphore);
    }];

    if (pid < 0) {
        // Execution failed
        result = [[ISHShellExecutionResult alloc] init];
        result.error = (ISHShellExecutorError)pid;
        result.exitCode = -1;
        return result;
    }

    // Wait for completion or timeout
    dispatch_time_t waitTime = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;

    long waitResult = dispatch_semaphore_wait(ctx.waitSemaphore, waitTime);

    if (waitResult != 0) {
        // Timeout - kill the process
        [self killProcess:pid withSignal:SIGKILL_];
        result = [[ISHShellExecutionResult alloc] init];
        result.error = ISHShellExecutorErrorTimeout;
        result.pid = pid;
        result.exitCode = -1;
        result.output = @"";
        result.errorOutput = @"";
    }

    return result;
}

+ (BOOL)killProcess:(int)pid withSignal:(int)signal {
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t)pid);
    if (task) {
        send_signal(task, signal, info);
    }
    unlock(&pids_lock);
    return task != NULL;
}

#pragma mark - Process Exit Handling

+ (void)processDidExit:(NSNotification *)notification {
    int pid = [notification.userInfo[@"pid"] intValue];
    int exitCode = [notification.userInfo[@"code"] intValue];

    ISHShellExecutionContext *ctx;
    @synchronized(_activeExecutions) {
        ctx = _activeExecutions[@(pid)];
        if (!ctx) return;
        [_activeExecutions removeObjectForKey:@(pid)];
    }

    @synchronized(ctx) {
        if (ctx.exitReceived) return;   // check-then-set 在同一把锁内, 无竞态
        ctx.exitReceived = YES;
        ctx.isCompleted = YES;          // reader 借此进入"排空后收尾"模式
        ctx.pendingExitCode = exitCode;
    }
    [ctx maybeFinalize];
}

#pragma mark - Pipe Reading

+ (void)startReaderForPipe:(int)fd context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    dispatch_async(_readerQueue, ^{
        [self readPipe:fd context:ctx isStdErr:isStdErr];
    });
}

+ (void)readPipe:(int)fd context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    char buffer[4096];
    NSMutableString *lineBuffer = [NSMutableString string];
    NSMutableString *outputBuffer = isStdErr ? ctx.stderrBuffer : ctx.stdoutBuffer;

    // 读取循环: 进程退出(isCompleted)后仍继续排空管道, 直到非阻塞读返回 EAGAIN,
    // 保证结果缓冲不再丢失尾部数据(旧实现退出即丢尾)。
    while (1) {
        ssize_t bytesRead = read(fd, buffer, sizeof(buffer) - 1);

        if (bytesRead > 0) {
            buffer[bytesRead] = '\0';
            NSString *chunk = [[NSString alloc] initWithBytes:buffer
                                                       length:bytesRead
                                                     encoding:NSUTF8StringEncoding];
            if (!chunk) {
                // Fallback to Latin1 for binary data
                chunk = [[NSString alloc] initWithBytes:buffer
                                                 length:bytesRead
                                               encoding:NSISOLatin1StringEncoding];
            }

            [lineBuffer appendString:chunk];

            // Process complete lines
            [self processLines:lineBuffer
                       context:ctx
                  outputBuffer:outputBuffer
                      isStdErr:isStdErr];

        } else if (bytesRead == 0) {
            // EOF - pipe closed
            break;
        } else {
            // Error or would block
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (ctx.isCompleted) {
                    break;              // 已退出且管道排空 → 收尾
                }
                usleep(10000); // 10ms
                continue;
            } else {
                break;
            }
        }
    }

    // Process any remaining partial line
    if (lineBuffer.length > 0) {
        @synchronized(outputBuffer) {
            if (outputBuffer.length < ISH_MAX_CAPTURE_BYTES) {
                [outputBuffer appendString:lineBuffer];
            } else {
                ctx.outputTruncated = YES;
            }
        }

        if (ctx.lineCallback) {
            [ctx enqueueLine:[lineBuffer copy] isStdErr:isStdErr];
        }
    }

    @synchronized(ctx) {
        ctx.readersFinished++;
    }
    [ctx maybeFinalize];
}

+ (void)processLines:(NSMutableString *)lineBuffer
             context:(ISHShellExecutionContext *)ctx
        outputBuffer:(NSMutableString *)outputBuffer
            isStdErr:(BOOL)isStdErr {

    while (YES) {
        NSRange newlineRange = [lineBuffer rangeOfString:@"\n"];
        if (newlineRange.location == NSNotFound) {
            break;
        }

        // Extract line without newline
        NSString *line = [lineBuffer substringToIndex:newlineRange.location];

        // Remove processed line from buffer
        [lineBuffer deleteCharactersInRange:NSMakeRange(0, newlineRange.location + 1)];

        // Add to output buffer (带上限, 防止无限累积内存)
        @synchronized(outputBuffer) {
            if (outputBuffer.length < ISH_MAX_CAPTURE_BYTES) {
                [outputBuffer appendString:line];
                [outputBuffer appendString:@"\n"];
            } else {
                ctx.outputTruncated = YES;
            }
        }

        // Call line callback（批量派发, 见 enqueueLine/drainPendingLines）
        if (ctx.lineCallback) {
            [ctx enqueueLine:line isStdErr:isStdErr];
        }
    }
}

@end
