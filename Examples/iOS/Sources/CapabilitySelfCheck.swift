//
//  CapabilitySelfCheck.swift
//  AppAgentDemo
//
//  In-simulator smoke test for the agent's host-introspection + session tools.
//  Runs each capability tool DIRECTLY (no LLM needed) against a live session and
//  returns a human-readable report, so every feature can be exercised and eyeballed
//  in the simulator without a model round-trip.
//

import UIKit

enum CapabilitySelfCheck {

    /// Run every capability tool once and format the results as a report.
    static func run(session: AISession) async -> String {
        var lines: [String] = []
        func section(_ title: String) { lines.append("\n=== \(title) ===") }

        func exec(_ tool: any ToolProtocol, _ args: [String: JSONValue]) async -> String {
            do {
                let out = try await tool.execute(arguments: args, session: session)
                return out.stringValue
            } catch {
                return "throw: \(error.localizedDescription)"
            }
        }

        func trimmed(_ s: String, _ max: Int = 600) -> String {
            s.count <= max ? s : String(s.prefix(max)) + "…(truncated)"
        }

        // 1) Multi-session self-awareness
        section("session_manage / list")
        lines.append(trimmed(await exec(SessionManageTool(), ["op": .string("list")])))

        // 2) UI view hierarchy
        let runtime = RuntimeInspectTool(provider: DefaultRuntimeInspectProvider())
        section("app_runtime_inspect / ui_hierarchy")
        lines.append(trimmed(await exec(runtime, ["op": .string("ui_hierarchy")])))

        // 3) Runtime: class list (filtered) + methods/properties of a known class
        section("app_runtime_inspect / class_list (filter: HostTabBar)")
        lines.append(trimmed(await exec(runtime, ["op": .string("class_list"), "filter": .string("HostTabBar")])))

        section("app_runtime_inspect / property_list (UILabel)")
        lines.append(trimmed(await exec(runtime, ["op": .string("property_list"), "class": .string("UILabel")])))

        // 4) KVC get/set on the top view controller's view
        section("app_runtime_inspect / property_value (view.tag via KVC)")
        lines.append(trimmed(await exec(runtime, ["op": .string("property_value"), "keyPath": .string("view.tag")])))

        // 5) Sandbox file read/write/list
        let sandbox = AppSandboxFileTool()
        section("app_sandbox_file / write + read + list")
        _ = await exec(sandbox, ["op": .string("write"),
                                 "path": .string("Documents/selfcheck.txt"),
                                 "content": .string("hello-selfcheck")])
        lines.append("read → " + trimmed(await exec(sandbox, ["op": .string("read"), "path": .string("Documents/selfcheck.txt")])))
        lines.append("list → " + trimmed(await exec(sandbox, ["op": .string("list"), "path": .string("Documents")])))

        // 6) UserDefaults read/write
        let defaults = AppUserDefaultsTool()
        section("app_user_defaults / write + read")
        _ = await exec(defaults, ["op": .string("write"),
                                  "key": .string("selfcheck_flag"),
                                  "value": .string("42")])
        lines.append("read → " + trimmed(await exec(defaults, ["op": .string("read"), "key": .string("selfcheck_flag")])))

        return lines.joined(separator: "\n")
    }

    /// Build a throwaway agent + session so the self-check can run even when the
    /// demo has no usable provider config (tool.execute never calls the model).
    ///
    /// `AISession.agentMask` holds only a *weak* back-reference to its agent, so
    /// the ephemeral agent must be retained for the lifetime of the check —
    /// otherwise `session_manage` sees a detached session. We park it in a static
    /// strong holder.
    private static var retainedEphemeralAgent: AIAgent?

    static func ephemeralSession() async -> AISession {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "selfcheck",
            profile: AIAgentProfile(identity: "selfcheck"),
            sessionStorage: InMemorySessionStorage()
        )
        retainedEphemeralAgent = agent
        return await agent.createSession(title: "自检")
    }
}

/// Weak shared handle to the demo's agent + active session so the host UI (a
/// button on the Home tab) can run the self-check without threading references
/// through the whole view hierarchy.
enum DemoAgentHolder {
    static weak var agent: AIAgent?
    static var currentSessionId: String?

    static func currentSession() -> AISession? {
        guard let agent else { return nil }
        if let id = currentSessionId, let s = agent.session(id: id) { return s }
        return agent.allSessions.first
    }
}
