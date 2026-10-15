import Foundation

/// A host-supplied execution boundary, independent of tool safety and user approval.
/// Return a reason to reject, or nil to continue through the existing safety checks.
/// Implementations must not perform tool effects or request authorization here.
/// Use the session's currentTurnID and genuine user messages for turn-specific policy;
/// model-produced tool arguments are not evidence of user authorization.
public protocol ToolExecutionGate: Sendable {
    func rejection(
        for tool: any ToolProtocol,
        arguments: [String: JSONValue],
        session: AISession
    ) async -> String?

    /// Called before the child's first user message. Freeze the parent's permission
    /// ceiling here: the generated child goal must not grant additional authority.
    func prepareDelegation(from parent: AISession, to child: AISession) async
}

extension ToolExecutionGate {
    public func prepareDelegation(from parent: AISession, to child: AISession) async {
    }
}

enum ToolExecutionAccess {
    struct Rejection: LocalizedError {
        let reason: String

        var errorDescription: String? {
            reason
        }
    }

    static func requireAllowed(
        _ tool: any ToolProtocol, arguments: [String: JSONValue], session: AISession
    ) async throws {
        try Task.checkCancellation()
        let turnID = session.currentTurnID
        if let gate = session.agentMask?.profile.toolExecutionGate,
           let reason = await gate.rejection(for: tool, arguments: arguments, session: session) {
            throw Rejection(reason: reason)
        }
        try Task.checkCancellation()
        guard session.currentTurnID == turnID else {
            throw Rejection(reason: "Tool execution rejected because the user turn changed.")
        }
    }
}
