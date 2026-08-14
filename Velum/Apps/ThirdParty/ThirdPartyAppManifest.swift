//
//  ThirdPartyAppManifest.swift
//  Velum
//
//  第三方 App 清单：描述一个已安装第三方 App 的元数据、运行方式与权限声明。
//  对应 doc&&blueprints/92-third-party-app-program.md 附录 A 的 manifest.json。
//
//  注意：这与 ControlPlane/VelumAction.swift 里的占位 `AppManifest`（仅 id+name，
//  供 VelumAction.launchApp 使用）是两个不同类型，勿混淆。
//

import Foundation

/// 第三方 App 清单（Codable，可序列化到 UserDefaults / 文件）。
public struct ThirdPartyAppManifest: Codable, Identifiable, Hashable, Sendable {
    /// 反向域名风格唯一 id，如 "com.example.demo"。
    public let id: String
    public var name: String
    public var version: String
    public var form: AppForm
    /// SF Symbol 名（第三方自定义图标走资源路径，后续扩展）。
    public var icon: String
    public var category: String
    public var author: String
    /// 申请的 iOS 资源权限（clipboard / notify / location / photos / camera / lan / hostfs-ro）。
    public var permissions: [String]
    public var runtime: Runtime

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        form: AppForm,
        icon: String? = nil,
        category: String = "other",
        author: String = "",
        permissions: [String] = [],
        runtime: Runtime
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.form = form
        self.icon = icon ?? form.systemImage
        self.category = category
        self.author = author
        self.permissions = permissions
        self.runtime = runtime
    }

    /// 运行方式。
    public struct Runtime: Codable, Hashable, Sendable {
        /// 启动命令（elfBridge 的 CLI/守护进程；webService 的后端服务）。iSH 内执行。
        public var command: String?
        /// 工作目录（默认 App 沙箱根）。
        public var cwd: String?
        /// webService 内部端口（实际由 Control Plane 分配；0 = 使用 url）。
        public var port: Int
        /// webService 直接书签 URL（外部或已运行服务）。
        public var url: String?
        /// h5Package 入口文件（相对沙箱根）。
        public var entry: String

        public init(command: String? = nil, cwd: String? = nil, port: Int = 0,
                    url: String? = nil, entry: String = "index.html") {
            self.command = command
            self.cwd = cwd
            self.port = port
            self.url = url
            self.entry = entry
        }

        // 显式解码：port / entry 在 JSON 中可缺省，使用 init 的默认值。
        // 避免每个形态的 manifest 都得写出与自身无关的字段
        // （h5Package 不需要 port，webService 不需要 entry）。
        private enum CodingKeys: String, CodingKey {
            case command, cwd, port, url, entry
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.command = try c.decodeIfPresent(String.self, forKey: .command)
            self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
            self.url = try c.decodeIfPresent(String.self, forKey: .url)
            self.entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? "index.html"
        }
    }

    // MARK: 校验（安装链安全）

    /// id 白名单：反向域名风格。仅小写字母/数字/点/下划线/连字符，
    /// 必须含至少一个点，不含连续点，不以点/连字符/下划线结尾。
    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, id.contains("."), !id.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let first = id.first, let last = id.last else { return false }
        return first != "." && last != "." && last != "-" && last != "_"
    }

    /// 入口文件安全：必须是相对路径，且不含 .. 分段。
    public var isEntrySafe: Bool {
        let e = runtime.entry
        guard !e.hasPrefix("/") else { return false }
        return e.split(separator: "/").allSatisfy { $0 != ".." && $0 != "." }
    }

    /// runtime 整体安全：h5/elf 校验入口文件；webService 校验 url scheme 与端口范围；
    /// cwd（若有）必须落在本 App 沙箱内且不含单引号（防止 shell 拼接逃逸）。
    public var isRuntimeSafe: Bool {
        if let cwd = runtime.cwd, !cwd.isEmpty {
            guard !cwd.contains("'"),
                  cwd == sandboxRoot || cwd.hasPrefix(sandboxRoot + "/") else { return false }
        }
        switch form {
        case .h5Package, .elfBridge:
            return isEntrySafe
        case .webService:
            if let u = runtime.url, !u.isEmpty {
                guard let url = URL(string: u), let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) else { return false }
                return true
            }
            return (0...65535).contains(runtime.port)
        }
    }

    /// 安装前综合校验。返回 nil 表示通过；否则返回人读的错误描述。
    public var installSafetyIssue: String? {
        if !Self.isValidID(id) { return "id 非法（需反向域名风格小写标识符）" }
        if !isEntrySafe { return "入口文件必须为沙箱内相对路径" }
        if !isRuntimeSafe { return "runtime 配置非法（端口越界或 URL scheme 不受支持）" }
        return nil
    }

    // MARK: 派生路径

    /// App 在 iSH fakefs 内的沙箱根目录。
    public var sandboxRoot: String { "/var/lib/velum/apps/\(id)" }

    /// h5Package 入口的 fakefs 绝对路径。
    public var entryPath: String { "\(sandboxRoot)/\(runtime.entry)" }

    /// webService 最终加载的 URL：优先显式 url，否则本地分配端口。
    public var effectiveURLString: String {
        if let u = runtime.url, !u.isEmpty { return u }
        let p = runtime.port > 0 ? runtime.port : 8080
        return "http://127.0.0.1:\(p)"
    }

    /// 是否声明了某项权限。
    public func hasPermission(_ p: String) -> Bool { permissions.contains(p) }
}
