import Foundation

/// Shared tool-input JSON Schema encoding for every built-in wire protocol.
enum ToolSchemaMapper {
    /// Build the JSON Schema dict from an Tool.Schema.
    static func inputSchema(_ schema: Tool.Schema) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (key, prop) in schema.properties {
            properties[key] = buildJSONSchema(prop)
        }

        return [
            "type": "object",
            "properties": properties,
            "required": schema.required
        ]
    }

    /// Build a single property's JSON Schema dict from a JSONSchema enum.
    private static func buildJSONSchema(_ schema: JSONSchema) -> [String: Any] {
        switch schema {
        case .string(let desc, let enumValues, let defaultValue):
            var dict: [String: Any] = ["type": "string"]
            if let desc { dict["description"] = desc }
            if let enumValues { dict["enum"] = enumValues }
            if let defaultValue { dict["default"] = jsonValueToAny(defaultValue) }
            return dict

        case .number(let desc, let minimum, let maximum, let defaultValue):
            var dict: [String: Any] = ["type": "number"]
            if let desc { dict["description"] = desc }
            if let minimum { dict["minimum"] = minimum }
            if let maximum { dict["maximum"] = maximum }
            if let defaultValue { dict["default"] = jsonValueToAny(defaultValue) }
            return dict

        case .integer(let desc, let minimum, let maximum, let defaultValue):
            var dict: [String: Any] = ["type": "integer"]
            if let desc { dict["description"] = desc }
            if let minimum { dict["minimum"] = minimum }
            if let maximum { dict["maximum"] = maximum }
            if let defaultValue { dict["default"] = jsonValueToAny(defaultValue) }
            return dict

        case .boolean(let desc, let defaultValue):
            var dict: [String: Any] = ["type": "boolean"]
            if let desc { dict["description"] = desc }
            if let defaultValue { dict["default"] = jsonValueToAny(defaultValue) }
            return dict

        case .array(let desc, let items, let maxItems):
            var dict: [String: Any] = ["type": "array"]
            if let desc { dict["description"] = desc }
            if let items { dict["items"] = buildJSONSchema(items) }
            if let maxItems { dict["maxItems"] = maxItems }
            return dict

        case .object(let desc, let properties, let required):
            var dict: [String: Any] = ["type": "object"]
            if let desc { dict["description"] = desc }
            if let properties {
                var nested: [String: Any] = [:]
                for (key, prop) in properties {
                    nested[key] = buildJSONSchema(prop)
                }
                dict["properties"] = nested
            }
            if let required { dict["required"] = required }
            return dict
        }
    }

    /// Convert JSONValue to Any for JSON serialization.
    private static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj { dict[k] = jsonValueToAny(v) }
            return dict
        }
    }

}
