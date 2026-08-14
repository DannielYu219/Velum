//
//  ISHBridge.swift
//  Velum
//
//  Phase 3.1 + 3.2 + 3.3: Swift async/await facade over iSH.
//
//  Wraps:
//  - ISHShellExecutor (exec commands, line-by-line output, streaming)
//  - ISHFsBridge      (fakefs readdir / read / write / stat / exists / readlink)
//
//  All shell execution uses ISHShellExecutor's existing, product-grade plumbing
//  (pipe creation, line splitting, ProcessExitedNotification listener). We only
//  add `withCheckedContinuation` / `AsyncThrowingStream` to bridge callbacks →
//  Swift concurrency. No new kernel-interaction code.
//
//  All fs operations are offloaded to ISHFsBridge's serial queue. We await them
//  via `Task.detached` so the serial queue is never blocked waiting on itself.
//

import Foundation

// MARK: - Execution Result

public struct ISHExecResult: Sendable {
    public let exitCode: Int32
    public let pid: Int32
    public let output: String
    public let errorOutput: String
    public let duration: TimeInterval

    public var isSuccess: Bool { exitCode == 0 }
}

// MARK: - Filesystem Types

public struct ISHDirEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let inode: UInt64
    public let size: UInt64
    public let mode: UInt16
    public let mtime: TimeInterval

    public var id: String { name }

    public var isDirectory: Bool { (mode & 0o170000) == 0o040000 }   // S_IFDIR
    public var isRegularFile: Bool { (mode & 0o170000) == 0o100000 } // S_IFREG
    public var isSymlink: Bool { (mode & 0o170000) == 0o120000 }     // S_IFLNK
    public var permissionBits: UInt16 { mode & 0o7777 }
}

public struct ISHFileStat: Sendable {
    public let size: UInt64
    public let mode: UInt16
    public let uid: UInt32
    public let gid: UInt32
    public let inode: UInt64
    public let nlink: UInt64
    public let mtime: TimeInterval
}

// MARK: - Errors

public enum ISHBridgeError: LocalizedError {
    case shellFailed(Int32)        // negative PID → process creation / exec failure
    case timedOut(String)          // command exceeded timeout (guest process killed)
    case fsError(Error)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .shellFailed(let code): return "iSH shell execution failed (code \(code))"
        case .timedOut(let cmd):     return "命令超时（已终止）：\(cmd)"
        case .fsError(let err):     return "iSH fs error: \(err.localizedDescription)"
        case .unexpected(let msg):  return "ISHBridge: \(msg)"
        }
    }
}

/// 一次性 resume 闸门：保证 continuation 只被 resume 一次（超时/完成/取消三路竞态）。
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var onResumedAction: (() -> Void)?

    /// 首次调用返回 true 并执行登记的动作；之后一律 false。
    @discardableResult
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        if let action = onResumedAction { action() }
        return true
    }

    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    /// 登记首次 claim 时要执行的动作（例如取消超时任务）。
    func onClaimed(_ action: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if resumed { action() } else { onResumedAction = action }
    }
}

/// 简单锁保护的变量盒（跨线程传递 pid 等）。
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
}

// MARK: - ISHBridge actor

public actor ISHBridge {

    public static let shared = ISHBridge()

    /// [性能/正确性] 专用 exec 后台队列。
    /// ISHShellExecutor 的 task_start 会把调用线程变成 guest 进程的宿主线程
    /// (该线程会被重命名为 comm-pid, 且退出前不归还线程池)。绝不能在主线程或
    /// actor 执行器上调用——否则 guest 进程会接管主线程(全 UI 卡顿)或饿死 actor。
    private nonisolated static let execQueue = DispatchQueue(label: "app.velum.ishexec", qos: .userInitiated)

    private init() {}

    // MARK: - Shell execution (one-shot, buffered)

    /// Execute a shell command via `/bin/sh -c`, buffer all output, return on completion.
    /// `timeout` 秒内未完成则 SIGKILL guest 进程并抛 `.timedOut`。
    /// Task 被取消时同样会 kill guest 进程并抛 CancellationError。
    ///
    /// [性能] nonisolated: exec 的同步初始化(become_new_init_child + do_execve,
    /// 含 fakefs 加载 ELF/动态链接器)不再占用 actor 的串行执行器——否则执行期间
    /// 全系统所有 fs/exec 桥调用都会被它排队, 表现为"执行时整个系统卡顿"。
    public nonisolated func execute(_ command: String, timeout: TimeInterval? = nil) async throws -> ISHExecResult {
        try await executeInternal(executable: "/bin/sh", arguments: ["-c", command],
                                  environment: nil, timeout: timeout, display: command)
    }

    /// Execute an executable with explicit arguments + environment.
    public nonisolated func executeExecutable(_ executable: String,
                                  arguments: [String] = [],
                                  environment: [String: String]? = nil,
                                  timeout: TimeInterval? = nil) async throws -> ISHExecResult {
        try await executeInternal(executable: executable, arguments: arguments,
                                  environment: environment, timeout: timeout,
                                  display: executable + " " + arguments.joined(separator: " "))
    }

    private nonisolated func executeInternal(executable: String, arguments: [String],
                                 environment: [String: String]?,
                                 timeout: TimeInterval?, display: String) async throws -> ISHExecResult {
        if Task.isCancelled { throw CancellationError() }
        let gate = ResumeGate()
        let pidBox = LockedBox<Int32>(-1)
        var contRef: CheckedContinuation<ISHExecResult, Error>? = nil

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ISHExecResult, Error>) in
                contRef = cont
                var collectedOut: [String] = []
                var collectedErr: [String] = []
                let collectLock = NSLock()

                // exec 初始化一律在专用后台队列上执行(见 execQueue 注释)。
                Self.execQueue.async {
                    // 在排队期间已被取消 → 不再启动进程。
                    if gate.isClaimed { return }

                    let pid = ISHShellExecutor.executeExecutable(
                        executable,
                        arguments: arguments,
                        environment: environment,
                        lineCallback: { line, isStdErr in
                            collectLock.lock()
                            if isStdErr { collectedErr.append(line) }
                            else        { collectedOut.append(line) }
                            collectLock.unlock()
                        },
                        completion: { result in
                            collectLock.lock()
                            let r = ISHExecResult(
                                exitCode: Int32(result.exitCode),
                                pid: Int32(result.pid),
                                output: collectedOut.joined(separator: "\n"),
                                errorOutput: collectedErr.joined(separator: "\n"),
                                duration: result.duration
                            )
                            collectLock.unlock()
                            let outcome: Result<ISHExecResult, Error> =
                                (result.exitCode == 0 || result.pid >= 0)
                                ? .success(r)
                                : .failure(ISHBridgeError.shellFailed(Int32(result.pid)))
                            if gate.claim() { cont.resume(with: outcome) }
                        }
                    )
                    pidBox.set(pid)

                    // 进程创建失败: completion 不会触发, 这里直接结束。
                    if pid < 0 {
                        if gate.claim() { cont.resume(throwing: ISHBridgeError.shellFailed(Int32(pid))) }
                        return
                    }

                    // 超时看护: 到期 kill + 抛错 (与 completion 竞态由 gate 保证只触发一次)。
                    if let timeout, timeout > 0 {
                        let timeoutTask = Task { [gate] in
                            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                            if !Task.isCancelled {
                                _ = ISHShellExecutor.killProcess(pid, withSignal: 9)
                                if gate.claim() { cont.resume(throwing: ISHBridgeError.timedOut(display)) }
                            }
                        }
                        gate.onClaimed { timeoutTask.cancel() }
                    }
                }
            }
        } onCancel: {
            // 取消 → kill guest 进程, 防止泄漏; gate 保证不重复 resume。
            if gate.claim() {
                let pid = pidBox.get()
                if pid > 0 { _ = ISHShellExecutor.killProcess(pid, withSignal: 9) }
                contRef?.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: - Shell execution (streaming)

    /// Execute a shell command and yield output lines as an `AsyncThrowingStream`.
    /// The stream terminates with `.finish` when the process exits.
    /// Non-zero exit is reported via throwing `ISHBridgeError.shellFailed` only
    /// when PID creation failed — non-zero exits are delivered as a final
    /// `.end`-style event with the exit code embedded in the stream's thrown error.
    /// [性能] nonisolated, 同 execute: 流式执行的初始化也不占用 actor 串行执行器。
    /// exec 初始化在专用后台队列执行(见 execQueue 注释), 绝不上主线程/调用线程。
    public nonisolated func executeStreaming(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // 完成标记: 正常结束后 onTermination 不再 kill, 避免误杀 pid 被复用的新进程。
            let finished = ResumeGate()
            // 丢弃标记: 流在 exec 开始前就被终止时, 阻止进程启动。
            let dropped = ResumeGate()
            let pidBox = LockedBox<Int32>(-1)

            Self.execQueue.async {
                if dropped.isClaimed { return }
                let pid = ISHShellExecutor.executeCommand(
                    command,
                    lineCallback: { line, _ in
                        continuation.yield(line)
                    },
                    completion: { result in
                        finished.claim()
                        if result.exitCode != 0 && result.pid >= 0 {
                            // Non-zero exit — surface as error so callers can distinguish.
                            continuation.finish(throwing: ISHBridgeError.shellFailed(Int32(result.exitCode)))
                        } else if result.pid < 0 {
                            continuation.finish(throwing: ISHBridgeError.shellFailed(Int32(result.pid)))
                        } else {
                            continuation.finish()
                        }
                    }
                )
                pidBox.set(pid)
                if pid < 0 {
                    finished.claim()
                    continuation.finish(throwing: ISHBridgeError.shellFailed(Int32(pid)))
                } else if dropped.isClaimed {
                    // exec 期间流已被丢弃 → 立即清理。
                    _ = ISHShellExecutor.killProcess(pid, withSignal: 9)
                }
            }
            // 取消传播: 消费者丢弃流时 kill 仍在运行的进程 (已正常结束则不 kill)。
            continuation.onTermination = { _ in
                dropped.claim()
                let pid = pidBox.get()
                if pid > 0 && !finished.isClaimed {
                    _ = ISHShellExecutor.killProcess(pid, withSignal: 9) // SIGKILL
                }
            }
        }
    }

    /// Kill a running guest process.
    public nonisolated func kill(pid: Int32, signal: Int32 = 9) async -> Bool {
        ISHShellExecutor.killProcess(pid, withSignal: signal)
    }

    // MARK: - Filesystem (fakefs)

    /// List directory entries.
    public func listDir(_ path: String) async throws -> [ISHDirEntry] {
        try await runOnFsQueue { try ISHFsBridge.sharedInstance().listDir(path).map { e in
            ISHDirEntry(name: e.name, inode: e.inode, size: e.size,
                        mode: e.mode, mtime: TimeInterval(e.mtime))
        } }
    }

    /// Stat a path.
    public func stat(_ path: String) async throws -> ISHFileStat {
        try await runOnFsQueue {
            let s = try ISHFsBridge.sharedInstance().statPath(path)
            return ISHFileStat(size: s.size, mode: s.mode, uid: s.uid, gid: s.gid,
                               inode: s.inode, nlink: s.nlink, mtime: TimeInterval(s.mtime))
        }
    }

    /// Check if a path exists.
    public func exists(_ path: String) async -> Bool {
        (try? await runOnFsQueue { ISHFsBridge.sharedInstance().exists(path) }) ?? false
    }

    /// Read up to `length` bytes (default 1MB) starting at `offset`.
    public func readFile(_ path: String, offset: Int = 0, length: Int = 1_048_576) async throws -> Data {
        try await runOnFsQueue {
            try ISHFsBridge.sharedInstance().readFile(path, offset: off_t(offset),
                                                      length: size_t(length))
        }
    }

    /// 读取整个文件（分块循环，绕过单次 1MB 限制）。
    /// 超过 `maxBytes` 的部分不返回——调用方可用 `stat` 判断是否被截断。
    public func readFileWhole(_ path: String, maxBytes: Int = 16_777_216) async throws -> Data {
        let s = try await stat(path)
        guard (s.mode & 0o170000) == 0o100000 else {   // S_IFREG
            throw ISHBridgeError.unexpected("not a regular file: \(path)")
        }
        let total = min(Int(s.size), max(0, maxBytes))
        guard total > 0 else { return Data() }
        var data = Data(capacity: total)
        var offset = 0
        while data.count < total {
            let want = min(total - data.count, 1_048_576)
            let piece = try await readFile(path, offset: offset, length: want)
            if piece.isEmpty { break }
            data.append(piece)
            offset += piece.count
        }
        return data
    }

    /// Read a file as UTF-8 string (whole file, 16MB cap; larger files are truncated).
    public func readTextFile(_ path: String) async throws -> String {
        let data = try await readFileWhole(path)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Write data to a path (truncates if exists, creates with mode 0755).
    public func writeFile(_ path: String, data: Data) async throws -> Int {
        try await runOnFsQueue {
            var error: NSError?
            let written = ISHFsBridge.sharedInstance().writeFile(path, data: data, error: &error)
            if let error { throw ISHBridgeError.fsError(error) }
            return Int(written)
        }
    }

    /// Write a UTF-8 string to a path.
    public func writeTextFile(_ path: String, text: String) async throws -> Int {
        try await writeFile(path, data: Data(text.utf8))
    }

    /// Delete a file/symlink, or a directory when `recursive` is true.
    /// 不走 shell 拼接, 无命令注入面。
    public func removePath(_ path: String, recursive: Bool = false) async throws {
        // ObjC 的 error:(NSError**) 参数被 Swift 导入为 throws, 直接 try 即可。
        _ = try await runOnFsQueue {
            try ISHFsBridge.sharedInstance().deletePath(path, recursive: recursive)
        }
    }

    /// Read symlink target. Returns nil if path is not a symlink.
    public func readlink(_ path: String) async throws -> String {
        try await runOnFsQueue {
            try ISHFsBridge.sharedInstance().readlinkPath(path)
        }
    }

    // MARK: - Private fs queue bridge

    /// Run a closure on ISHFsBridge's serial queue (via `Task.detached` so we
    /// don't block the actor's executor) and await its result.
    private func runOnFsQueue<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try body()
        }.value
    }
}

// MARK: - Convenience: list + format

public extension ISHDirEntry {
    /// Human-readable size, e.g. "1.2 KB". Returns "—" for directories.
    var formattedSize: String {
        guard isRegularFile else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// Short permission string, e.g. "rwxr-xr-x".
    var permissionString: String {
        let perms = permissionBits
        var s = [Character](repeating: "-", count: 9)
        if perms & 0o400 != 0 { s[0] = "r" }
        if perms & 0o200 != 0 { s[1] = "w" }
        if perms & 0o100 != 0 { s[2] = "x" }
        if perms & 0o040 != 0 { s[3] = "r" }
        if perms & 0o020 != 0 { s[4] = "w" }
        if perms & 0o010 != 0 { s[5] = "x" }
        if perms & 0o004 != 0 { s[6] = "r" }
        if perms & 0o002 != 0 { s[7] = "w" }
        if perms & 0o001 != 0 { s[8] = "x" }
        return String(s)
    }
}
