//
//  HostInfoTool.swift
//  AppAgent
//

import Foundation

/// Host-owned additions to the SDK's automatically available app identity.
public protocol HostInfoProvider: Sendable {
    func additionalHostInfo() async -> [String: JSONValue]
}

/// Reports the identity and build information of the host app.
///
/// Bundle metadata is available without host code. A host may inject a provider
/// to add non-sensitive product or environment fields under `custom`.
public struct HostInfoTool: ToolProtocol {
    public let name = "host_info"
    public let description = """
        Read host app identity and runtime build information. \
        Choose a section to keep the result small: identity, build, or custom.
        """
    public let parameters = Tool.Schema(
        properties: [
            "section": .string(
                description: "Which host information to return. Omit or use 'all' for everything.",
                enumValues: ["all", "identity", "build", "custom"],
                defaultValue: .string("all")
            )
        ],
        required: []
    )
    public let group = "host-runtime"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: (any HostInfoProvider)?

    public init(provider: (any HostInfoProvider)? = nil) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let section = arguments["section"]?.stringValue ?? "all"
        let knownSections = ["all", "identity", "build", "custom"]
        guard knownSections.contains(section) else {
            return .error(
                "Unknown section '\(section)'. Use \(knownSections.joined(separator: ", "))."
            )
        }

        var result: [String: JSONValue] = [:]
        if section == "all" || section == "identity" {
            result["identity"] = Self.identitySection()
        }
        if section == "all" || section == "build" {
            result["build"] = Self.buildSection()
        }
        if section == "all" || section == "custom" {
            result["custom"] = .object(await provider?.additionalHostInfo() ?? [:])
        }
        return .json(.object(result))
    }

    private static func identitySection() -> JSONValue {
        let bundle = Bundle.main
        return .object([
            "bundle_id": .string(bundle.bundleIdentifier ?? "unknown"),
            "display_name": .string(
                (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? "unknown"
            )
        ])
    }

    private static func buildSection() -> JSONValue {
        let bundle = Bundle.main
        let configuration = bundle.object(
            forInfoDictionaryKey: "AppAgentHostBuildConfiguration"
        ) as? String
        var values: [String: JSONValue] = [
            "version": .string(
                (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                    ?? "unknown"
            ),
            "build": .string(
                (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
                    ?? "unknown"
            )
        ]
        if let configuration, !configuration.isEmpty {
            values["configuration"] = .string(configuration)
        }
        return .object(values)
    }
}
