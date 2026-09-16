//
//  AppUserDefaultsTool.swift
//  AppAgent
//
//  Host-storage tool: read, write, remove and list the app's UserDefaults.
//  Categorized under the "host-storage" group so it can be enabled/disabled
//  together with other host-introspection storage tools.
//

import Foundation

public struct AppUserDefaultsTool: ToolProtocol {
    public let name = "app_user_defaults"
    public let description = """
        Read and modify the host app's UserDefaults. Choose an 'op':
        - 'read': read the value for 'key'.
        - 'write': set 'key' to 'value' (string/number/bool/array/object).
        - 'remove': delete 'key'.
        - 'list': list stored keys (optional 'prefix' filter).
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.", enumValues: ["read", "write", "remove", "list"]),
            "key": .string(description: "Defaults key. Required for read/write/remove."),
            "value": .string(description: "Value to store for 'write'. JSON is parsed when possible, else stored as a string."),
            "prefix": .string(description: "Optional key prefix filter for 'list'.")
        ],
        required: ["op"]
    )
    public let group = "host-storage"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "read":
            guard let key = arguments["key"]?.stringValue else { return .error("'key' is required for read.") }
            let value = defaults.object(forKey: key)
            return .json(.object([
                "key": .string(key),
                "exists": .bool(value != nil),
                "value": Self.jsonValue(from: value)
            ]))
        case "write":
            guard let key = arguments["key"]?.stringValue else { return .error("'key' is required for write.") }
            guard let raw = arguments["value"]?.stringValue else { return .error("'value' is required for write.") }
            let stored = Self.parseValue(raw)
            defaults.set(stored, forKey: key)
            return .json(.object([
                "success": .bool(true),
                "key": .string(key),
                "value": Self.jsonValue(from: defaults.object(forKey: key))
            ]))
        case "remove":
            guard let key = arguments["key"]?.stringValue else { return .error("'key' is required for remove.") }
            defaults.removeObject(forKey: key)
            return .json(.object(["success": .bool(true), "key": .string(key)]))
        case "list":
            let prefix = arguments["prefix"]?.stringValue
            var keys = Array(defaults.dictionaryRepresentation().keys)
            if let prefix, !prefix.isEmpty {
                keys = keys.filter { $0.hasPrefix(prefix) }
            }
            keys.sort()
            return .json(.object([
                "count": .number(Double(keys.count)),
                "keys": .array(keys.map { .string($0) })
            ]))
        default:
            return .error("Unknown op: '\(op)'. Use 'read', 'write', 'remove', or 'list'.")
        }
    }

    // MARK: - Value bridging

    /// Parse a raw string into a plist-storable value: try JSON first, else store as string.
    static func parseValue(_ raw: String) -> Any {
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return obj
        }
        return raw
    }

    static func jsonValue(from any: Any?) -> JSONValue {
        guard let any else { return .null }
        switch any {
        case let n as NSNumber:
            // NSNumber backs both bool and numeric defaults; disambiguate via CFBoolean.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let arr as [Any]: return .array(arr.map { jsonValue(from: $0) })
        case let dict as [String: Any]:
            var obj: [String: JSONValue] = [:]
            for (k, v) in dict { obj[k] = jsonValue(from: v) }
            return .object(obj)
        case let data as Data: return .string("<data \(data.count) bytes>")
        default: return .string("\(any)")
        }
    }
}
