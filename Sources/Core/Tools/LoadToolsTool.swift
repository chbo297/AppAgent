//
//  LoadToolsTool.swift
//  AppAgent
//
//  按需加载工具组。组内工具平时不随请求发送（省上下文），系统提示词只列组名和用途；
//  模型调用本工具后，本会话之后的请求才带上这些工具的完整定义。
//

import Foundation

public struct LoadToolsTool: ToolProtocol {
    public static let toolName = "load_tools"

    public let name = LoadToolsTool.toolName
    public let description = """
        Load a group of tools listed under "Tools loaded on demand" in the system prompt. \
        After loading, the group's tools are available for the rest of this conversation.
        """
    public let parameters = Tool.Schema(
        properties: [
            "group": .string(description: "Group name from the system prompt, e.g. \"debug\".")
        ],
        required: ["group"]
    )
    public let group = ToolGroups.core
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let requested = arguments["group"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else {
            return .error("'group' is required.")
        }
        guard let central = session.agentMask?.toolCentral else {
            return .error("No tool registry is attached to this session.")
        }
        let groups = await central.deferredGroupSummaries()
        guard groups[requested] != nil else {
            let known = groups.keys.sorted().joined(separator: ", ")
            return .error("Unknown tool group '\(requested)'. Available: \(known.isEmpty ? "none" : known).")
        }
        session.markToolGroupLoaded(requested)
        let tools = await central.resolveTools().values.filter { tool in
            tool.deferredGroup == requested
        }
        let lines = tools.map(\.name).sorted().map { name in
            "- \(name)"
        }
        return .text("Loaded tool group '\(requested)':\n" + lines.joined(separator: "\n"))
    }
}
