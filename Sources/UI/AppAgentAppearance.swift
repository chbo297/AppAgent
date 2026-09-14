//
//  AppAgentAppearance.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

enum AppAgentAppearance {
    static let overlayBackground = dynamicColor(light: 0xF7F9FC, dark: 0x15181D)
    static let inputBarBackground = dynamicColor(light: 0xFFFFFF, dark: 0x272B31)
    static let inputBarBorder = dynamicColor(light: 0xE7ECF2, dark: 0x3A4048)
    static let primaryText = dynamicColor(light: 0x1D2430, dark: 0xF4F7FB)
    static let secondaryText = dynamicColor(light: 0x6B7280, dark: 0xAEB7C3)
    static let placeholderText = dynamicColor(light: 0x9AA4B2, dark: 0x8792A0)
    static let icon = dynamicColor(light: 0x111827, dark: 0xEEF2F7)
    static let accent = dynamicColor(light: 0x0A7AFF, dark: 0x5AC8FA)
    static let inputBarShadow = dynamicColor(light: 0x0F172A, dark: 0x000000)
    static let voicePressedBackground = dynamicColor(light: 0xEAF1FA, dark: 0x343A43)
    static let menuFill = dynamicColor(light: 0xFFFFFF, dark: 0x20242A)
    static let menuStroke = dynamicColor(light: 0x111827, dark: 0xF1F5F9)
    static let userBubbleBackground = dynamicColor(light: 0x0A7AFF, dark: 0x2F8CFF)
    static let assistantBubbleBackground = dynamicColor(light: 0xEEF3F8, dark: 0x252A31)
    static let errorBackground = dynamicColor(light: 0xFDE8E8, dark: 0x3A2024)
    static let errorText = dynamicColor(light: 0xC81E1E, dark: 0xFF8A8A)

    static func inputBarShadowOpacity(for traitCollection: UITraitCollection) -> Float {
        traitCollection.userInterfaceStyle == .dark ? 0.42 : 0.14
    }

    private static func dynamicColor(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor { traitCollection in
            rgb(traitCollection.userInterfaceStyle == .dark ? dark : light, alpha: alpha)
        }
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

#endif
