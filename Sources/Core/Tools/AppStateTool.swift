//
//  AppStateTool.swift
//  AppAgent
//

import Foundation

/// 让模型主动查一次宿主当前状态。
///
/// 读的就是会话装上的那个 `HostStateProvider`（每次请求模型前自动附带的也是它），
/// 宿主不用再单独实现一个接口。
public struct AppStateTool: ToolProtocol {
    public let name = "app_state"
    public let description = """
        Read the host app's current state right now: the same fields the host attaches to each request \
        (current page and other facts the app exposes), freshly read. Read-only. Each field is plain text.
        """
    public let parameters = Tool.Schema(properties: [:], required: [])
    public let group: String = "custom"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let fields = await session.hostStateReporter.readCurrentState() else {
            return .error("The host app has not provided any state.")
        }
        return .json(.object(fields.mapValues(JSONValue.string)))
    }
}
