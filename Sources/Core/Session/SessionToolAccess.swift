import Foundation

enum SessionToolAccess {
    static func isReadOnly(_ session: AISession) -> Bool {
        var current: AISession? = session
        var seen = Set<ObjectIdentifier>()
        while let value = current {
            guard seen.insert(ObjectIdentifier(value)).inserted else { return true }
            if value.executionPolicy.toolMutationPolicy == .readOnly { return true }
            current = value.decisionParent
        }
        return false
    }

    static func integer(_ arguments: [String: JSONValue], _ name: String,
                        default fallback: Int, clamp: ClosedRange<Int>? = nil) throws -> Int {
        guard let raw = arguments[name] else { return fallback }
        guard let number = raw.numberValue, number.isFinite, let value = Int(exactly: number) else {
            throw SessionLifecycleError.invalid("'\(name)' must be a finite, representable integer.")
        }
        guard let clamp else { return value }
        return min(clamp.upperBound, max(clamp.lowerBound, value))
    }
}
