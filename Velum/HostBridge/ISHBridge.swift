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
    case fsError(Error)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .shellFailed(let code): return "iSH shell execution failed (code \(code))"
        case .fsError(let err):     return "iSH fs error: \(err.localizedDescription)"
        case .unexpected(let msg):  return "ISHBridge: \(msg)"
        }
    }
}

// MARK: - ISHBridge actor

public actor ISHBridge {

    public static let shared = ISHBridge()

    private init() {}

    // MARK: - Shell execution (one-shot, buffered)

    /// Execute a shell command via `/bin/sh -c`, buffer all output, return on completion.
    public func execute(_ command: String) async throws -> ISHExecResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ISHExecResult, Error>) in
            var collectedOut: [String] = []
            var collectedErr: [String] = []

            let pid = ISHShellExecutor.executeCommand(
                command,
                lineCallback: { line, isStdErr in
                    if isStdErr { collectedErr.append(line) }
                    else        { collectedOut.append(line) }
                },
                completion: { result in
                    let r = ISHExecResult(
                        exitCode: Int32(result.exitCode),
                        pid: Int32(result.pid),
                        output: collectedOut.joined(separator: "\n"),
                        errorOutput: collectedErr.joined(separator: "\n"),
                        duration: result.duration
                    )
                    if result.exitCode == 0 {
                        cont.resume(returning: r)
                    } else if result.pid < 0 {
                        cont.resume(throwing: ISHBridgeError.shellFailed(Int32(result.pid)))
                    } else {
                        // Non-zero exit — return the result so caller can inspect exitCode.
                        cont.resume(returning: r)
                    }
                }
            )

            // If executeCommand returns a negative PID, process creation failed —
            // the completion callback will never fire.
            if pid < 0 {
                cont.resume(throwing: ISHBridgeError.shellFailed(Int32(pid)))
            }
        }
    }

    /// Execute an executable with explicit arguments + environment.
    public func executeExecutable(_ executable: String,
                                  arguments: [String] = [],
                                  environment: [String: String]? = nil) async throws -> ISHExecResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ISHExecResult, Error>) in
            var collectedOut: [String] = []
            var collectedErr: [String] = []

            let pid = ISHShellExecutor.executeExecutable(
                executable,
                arguments: arguments,
                environment: environment,
                lineCallback: { line, isStdErr in
                    if isStdErr { collectedErr.append(line) }
                    else        { collectedOut.append(line) }
                },
                completion: { result in
                    let r = ISHExecResult(
                        exitCode: Int32(result.exitCode),
                        pid: Int32(result.pid),
                        output: collectedOut.joined(separator: "\n"),
                        errorOutput: collectedErr.joined(separator: "\n"),
                        duration: result.duration
                    )
                    if result.exitCode == 0 || result.pid >= 0 {
                        cont.resume(returning: r)
                    } else {
                        cont.resume(throwing: ISHBridgeError.shellFailed(Int32(result.pid)))
                    }
                }
            )

            if pid < 0 {
                cont.resume(throwing: ISHBridgeError.shellFailed(Int32(pid)))
            }
        }
    }

    // MARK: - Shell execution (streaming)

    /// Execute a shell command and yield output lines as an `AsyncThrowingStream`.
    /// The stream terminates with `.finish` when the process exits.
    /// Non-zero exit is reported via throwing `ISHBridgeError.shellFailed` only
    /// when PID creation failed — non-zero exits are delivered as a final
    /// `.end`-style event with the exit code embedded in the stream's thrown error.
    public func executeStreaming(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let pid = ISHShellExecutor.executeCommand(
                command,
                lineCallback: { line, _ in
                    continuation.yield(line)
                },
                completion: { result in
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
            if pid < 0 {
                continuation.finish(throwing: ISHBridgeError.shellFailed(Int32(pid)))
            }
            // Propagate cancellation upstream: kill the process when the consumer drops the stream.
            continuation.onTermination = { _ in
                if pid > 0 {
                    _ = ISHShellExecutor.killProcess(pid, withSignal: 9) // SIGKILL
                }
            }
        }
    }

    /// Kill a running guest process.
    public func kill(pid: Int32, signal: Int32 = 9) async -> Bool {
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

    /// Read a file as UTF-8 string.
    public func readTextFile(_ path: String) async throws -> String {
        let data = try await readFile(path)
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
