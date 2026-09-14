//
//  JSONSchema.swift
//  AppAgent
//

import Foundation

/// Generic JSON Schema description (recursive structure).
///
/// Uses `indirect enum` to handle recursive references (array items, object properties),
/// following the pattern used by OpenAPIKit. Each case carries only the associated values
/// relevant to that JSON Schema type.
public indirect enum JSONSchema: Sendable {
    case string(
        description: String? = nil,
        enumValues: [String]? = nil,
        defaultValue: JSONValue? = nil
    )
    case number(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        defaultValue: JSONValue? = nil
    )
    case integer(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil,
        defaultValue: JSONValue? = nil
    )
    case boolean(
        description: String? = nil,
        defaultValue: JSONValue? = nil
    )
    case array(
        description: String? = nil,
        items: JSONSchema? = nil,
        maxItems: Int? = nil
    )
    case object(
        description: String? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil
    )
}
