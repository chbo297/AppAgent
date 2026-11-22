//
//  HostTools.swift
//  AppAgent
//
//  宿主工具与 SDK 内置工具的边界。
//
//  - SDK 内置工具（含宿主提供 provider 的 app_ui / app_web_inspect 等）用 `ToolCentral.register(_:)`，
//    名字原样交给模型。
//  - 宿主业务工具打包成一个 `HostToolSet`，经 `ToolCentral.registerHost(_:)` 注册：
//    宿主只写本地短名（如 "route"），SDK 对模型暴露 `<namespace>_<name>`（如 "bdmap_route"），
//    执行时原样转给宿主实现。重名一律注册失败，不会静默覆盖。
//  - 系统提示词只多一行来源说明（见 `ToolCentral.toolSourcesPrompt()`），模型平时按工具说明使用即可，
//    调试或排查时再看来源。
//

import Foundation

/// 一个宿主提供的一组工具。
public struct HostToolSet: Sendable {
    /// 模型侧名称前缀，如 "bdmap"。规则：小写字母开头，2–16 位小写字母或数字；
    /// 不能与 SDK 内置工具名的第一段重名（如 "app"、"file"、"session"）。
    public let namespace: String
    /// 给人和模型看的宿主名，如「百度地图」。
    public let displayName: String
    /// 一句话说明这组工具作用于什么，如「作用于百度地图的业务与页面」。
    public let summary: String
    /// 宿主工具，`name` 写本地短名。
    public let tools: [any ToolProtocol]
    /// 宿主自己的按需加载组：组名 → 一句话用途。宿主工具也可以直接加入 SDK 的组（如 "debug"）。
    public let deferredGroups: [String: String]

    public init(
        namespace: String,
        displayName: String,
        summary: String,
        tools: [any ToolProtocol],
        deferredGroups: [String: String] = [:]
    ) {
        self.namespace = namespace
        self.displayName = displayName
        self.summary = summary
        self.tools = tools
        self.deferredGroups = deferredGroups
    }
}

/// 工具来自哪里。
public enum ToolOrigin: Sendable, Equatable {
    case builtIn
    case host(namespace: String)
}

public enum ToolRegistrationError: LocalizedError, Equatable {
    case invalidNamespace(String)
    case reservedNamespace(String)
    case invalidToolName(String)
    case duplicateToolName(String)
    case unknownDeferredGroup(tool: String, group: String)

    public var errorDescription: String? {
        switch self {
        case .invalidNamespace(let namespace):
            return "Host tool namespace '\(namespace)' must be 2-16 lowercase letters or digits, starting with a letter."
        case .reservedNamespace(let namespace):
            return "Host tool namespace '\(namespace)' is reserved by an App Agent built-in tool."
        case .invalidToolName(let name):
            return "Tool name '\(name)' must be 1-64 characters of letters, digits, '_' or '-'."
        case .duplicateToolName(let name):
            return "Tool name '\(name)' is already registered."
        case .unknownDeferredGroup(let tool, let group):
            return "Tool '\(tool)' joins deferred group '\(group)', which is not registered."
        }
    }
}

/// 宿主工具在 SDK 里的包装：名字加上 namespace 前缀，其余全部转给宿主实现。
struct HostTool: ToolProtocol {
    let base: any ToolProtocol
    let namespace: String

    var name: String {
        "\(namespace)_\(base.name)"
    }
    var description: String {
        base.description
    }
    var parameters: Tool.Schema {
        base.parameters
    }
    var usageGuide: String? {
        base.usageGuide
    }
    var enabled: Bool {
        base.enabled
    }
    var group: String {
        base.group
    }
    var deferredGroup: String? {
        base.deferredGroup
    }
    var safetyLevel: Tool.SafetyLevel {
        base.safetyLevel
    }
    var outputMaxBytes: Int? {
        base.outputMaxBytes
    }
    var waitsForUser: Bool {
        base.waitsForUser
    }

    func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        base.safetyLevel(for: arguments)
    }

    func preflightRejection(for arguments: [String: JSONValue], session: AISession) async -> String? {
        await base.preflightRejection(for: arguments, session: session)
    }

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        try await base.execute(arguments: arguments, session: session)
    }
}

extension ToolProtocol {
    /// 工具来源：SDK 内置，或某个宿主 namespace。
    public var origin: ToolOrigin {
        if let host = self as? HostTool {
            return .host(namespace: host.namespace)
        }
        return .builtIn
    }

    /// 宿主注册时写的本地短名；内置工具等于 `name`。宿主的权限、边界策略按它判断。
    public var localName: String {
        if let host = self as? HostTool {
            return host.base.name
        }
        return name
    }
}

enum ToolNaming {
    /// 模型接口对工具名的要求：`[a-zA-Z0-9_-]{1,64}`。
    static func isValidToolName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64 else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                || scalar == "_" || scalar == "-"
        }
    }

    static func isValidNamespace(_ namespace: String) -> Bool {
        let scalars = Array(namespace.unicodeScalars)
        guard (2...16).contains(scalars.count), let first = scalars.first,
              ("a"..."z").contains(first) else {
            return false
        }
        return scalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        }
    }

    /// 内置工具名的第一段都不能拿来当宿主 namespace，否则 `<namespace>_x` 可能与内置工具撞名。
    static func reservedNamespaces(builtInNames: some Sequence<String>) -> Set<String> {
        var reserved: Set<String> = ["app", "appagent", "load"]
        for name in builtInNames {
            if let head = name.split(separator: "_").first {
                reserved.insert(String(head))
            }
        }
        return reserved
    }
}
