//
//  BuiltInMessageContext.swift
//  AppAgent
//

import Foundation

/// Framework-provided message context entries.
/// Always included in message context injection. Not configurable by host apps.
struct BuiltInMessageContext: MessageContextProvider {
    func messageContext() async -> [MessageContextEntry] {
        let now = Date()
        let tz = TimeZone.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Use user's local timezone; fall back to UTC if identifier is empty/unknown
        if tz.identifier.isEmpty || (tz.identifier == "GMT" && tz.secondsFromGMT() == 0
            && TimeZone.current.abbreviation() == nil) {
            formatter.timeZone = TimeZone(identifier: "UTC")
            let timeString = formatter.string(from: now)
            return [
                MessageContextEntry(label: "Current time", value: "\(timeString) (UTC)")
            ]
        }

        formatter.timeZone = tz
        let timeString = formatter.string(from: now)
        let tzAbbr = tz.abbreviation(for: now) ?? "UTC\(tz.secondsFromGMT() >= 0 ? "+" : "")\(tz.secondsFromGMT() / 3600)"
        return [
            MessageContextEntry(label: "Current time", value: "\(timeString) (\(tzAbbr))")
        ]
    }
}
