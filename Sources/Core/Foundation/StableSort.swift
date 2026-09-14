//
//  StableSort.swift
//  AppAgent
//

import Foundation

/// Shared stable-sort utility for name-based ordering.
///
/// All name/key sorting across the SDK should go through these methods
/// so the comparison strategy is defined in one place.
/// Currently uses case-sensitive Unicode code-point order (matches `<` on String).
public enum StableSort {

    /// Sort elements by a string key extracted via closure.
    public static func byName<T>(_ items: [T], key: (T) -> String) -> [T] {
        items.sorted { key($0) < key($1) }
    }

    /// Sort strings directly (for dictionary keys, provider names, etc.)
    public static func byName(_ items: [String]) -> [String] {
        items.sorted()
    }
}
