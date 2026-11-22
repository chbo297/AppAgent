//
//  FileResourceRegistry.swift
//  AppAgent
//

import Foundation

public enum FileResourceOwner: String, Sendable {
    case agent
    case host
}

public enum FileResourceOperation: String, CaseIterable, Hashable, Sendable {
    case list
    case read
    case write
    case search
    case delete
    case revealPath = "reveal_path"
}

public struct FileResourceDescriptor: Sendable {
    public let uri: String
    public let summary: String
    public let rootURL: URL
    public let hostSandboxRootURL: URL?
    public let owner: FileResourceOwner
    public let operations: Set<FileResourceOperation>

    public init(
        uri: String,
        summary: String,
        rootURL: URL,
        hostSandboxRootURL: URL? = nil,
        owner: FileResourceOwner,
        operations: Set<FileResourceOperation>
    ) {
        self.uri = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary
        self.rootURL = rootURL.standardizedFileURL
        self.hostSandboxRootURL = hostSandboxRootURL?.standardizedFileURL
        self.owner = owner
        self.operations = operations
    }

    var key: String {
        uri.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public struct FileResourceRegistry: Sendable {
    public let resources: [String: FileResourceDescriptor]

    public init(
        agentWorkspaceURL: URL? = nil,
        agentSessionsURL: URL? = nil,
        agentMemoryURL: URL? = nil,
        agentSkillsURL: URL? = nil,
        hostResources: [FileResourceDescriptor] = []
    ) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appAgentRoot = documents.appendingPathComponent("AppAgent", isDirectory: true)
        let workspace = agentWorkspaceURL ?? appAgentRoot.appendingPathComponent("files", isDirectory: true)
        let sessions = agentSessionsURL ?? appAgentRoot.appendingPathComponent("sessions", isDirectory: true)
        let memory = agentMemoryURL ?? appAgentRoot.appendingPathComponent("memory", isDirectory: true)
        let skills = agentSkillsURL ?? appAgentRoot.appendingPathComponent("skills", isDirectory: true)

        var values: [String: FileResourceDescriptor] = [:]
        let agentReadOnly: Set<FileResourceOperation> = [
            .list, .read, .search, .revealPath
        ]
        values["agent://workspace"] = FileResourceDescriptor(
            uri: "agent://workspace",
            summary: "Agent working files created by tools and host integrations.",
            rootURL: workspace,
            owner: .agent,
            operations: Set(FileResourceOperation.allCases)
        )
        values["agent://sessions"] = FileResourceDescriptor(
            uri: "agent://sessions",
            summary: "Persisted AppAgent sessions. Read-only; use session for lifecycle changes.",
            rootURL: sessions,
            owner: .agent,
            operations: agentReadOnly
        )
        values["agent://memory"] = FileResourceDescriptor(
            uri: "agent://memory",
            summary: "AppAgent memory storage. Read-only; use memory for semantic updates.",
            rootURL: memory,
            owner: .agent,
            operations: agentReadOnly
        )
        values["agent://skills"] = FileResourceDescriptor(
            uri: "agent://skills",
            summary: "Installed skill files. Read-only; use skill for skill lifecycle operations.",
            rootURL: skills,
            owner: .agent,
            operations: agentReadOnly
        )
        for resource in hostResources {
            values[resource.key] = resource
        }
        self.resources = values
    }

    public func adding(_ resource: FileResourceDescriptor) -> FileResourceRegistry {
        var result = resources
        result[resource.key] = resource
        return FileResourceRegistry(resources: result)
    }

    public func descriptor(for uri: String) -> FileResourceDescriptor? {
        guard let components = URLComponents(string: uri),
              let scheme = components.scheme,
              let host = components.host else {
            return nil
        }
        let key = "\(scheme)://\(host)"
        return resources[key]
    }

    public func resolve(_ uri: String) -> (descriptor: FileResourceDescriptor, relativePath: String)? {
        guard let descriptor = descriptor(for: uri),
              let components = URLComponents(string: uri),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }
        let rawPath = components.percentEncodedPath.removingPercentEncoding ?? components.path
        guard !rawPath.hasPrefix("//") else {
            return nil
        }
        let relativePath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (descriptor, relativePath.isEmpty ? "." : relativePath)
    }

    private init(resources: [String: FileResourceDescriptor]) {
        self.resources = resources
    }
}

public extension FileResourceDescriptor {
    static func host(
        name: String,
        summary: String,
        rootURL: URL,
        hostSandboxRootURL: URL? = nil,
        operations: Set<FileResourceOperation> = [.list, .read, .search, .revealPath]
    ) -> FileResourceDescriptor {
        FileResourceDescriptor(
            uri: "host://\(name)",
            summary: summary,
            rootURL: rootURL,
            hostSandboxRootURL: hostSandboxRootURL,
            owner: .host,
            operations: operations
        )
    }
}
