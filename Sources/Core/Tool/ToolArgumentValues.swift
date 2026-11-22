import Foundation

/// JSON Schema describes arguments to the model; tools must still validate values at runtime.
enum ToolArgumentValues {
    static func integer(_ arguments: [String: JSONValue], _ name: String,
                        default fallback: Int, range: ClosedRange<Int> = 1...Int.max) -> Int? {
        guard let raw = arguments[name] else { return fallback }
        guard let number = raw.numberValue, number.isFinite,
              let value = Int(exactly: number), range.contains(value) else { return nil }
        return value
    }
}
