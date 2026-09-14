//
//  HapticTool.swift
//  AppAgent
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Tool for triggering haptic feedback on the device.
public struct HapticTool: ToolProtocol {
    public let name = "haptic"
    public let description = """
        Trigger haptic feedback on the device. \
        Styles: 'light', 'medium', 'heavy' for impact; \
        'success', 'warning', 'error' for notification; 'selection' for selection change.
        """
    public let parameters = Tool.Schema(
        properties: [
            "style": .string(
                description: "Haptic feedback style.",
                enumValues: ["light", "medium", "heavy", "success", "warning", "error", "selection"],
                defaultValue: .string("medium")
            )
        ],
        required: []
    )
    public let group: String = "system"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let style = arguments["style"]?.stringValue ?? "medium"

        #if canImport(UIKit)
        await MainActor.run {
            switch style {
            case "light":
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "medium":
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "heavy":
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "success":
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning":
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error":
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "selection":
                UISelectionFeedbackGenerator().selectionChanged()
            default:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        return .json(.object([
            "success": .bool(true),
            "style": .string(style)
        ]))
        #else
        return .json(.object([
            "success": .bool(false),
            "message": .string("Haptic feedback is not available on this platform.")
        ]))
        #endif
    }
}
