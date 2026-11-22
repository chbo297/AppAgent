//
//  HostToolset.swift
//  AppAgent — 宿主能力工具装配
//
//  按宿主注入的 provider 组装「界面操作 / 运行时内省 / 网页内省 / 热修复」这类 SDK 定义的宿主能力工具。
//  宿主拿到数组后用 ToolCentral.register(_:) 注册（名字原样暴露，属于 SDK 内置工具）。
//
//  ⚠️ 领域/业务能力不在此处：按「AppAgent 只做通用机制与协议，业务能力由宿主实现并注册」的
//  设计约束，宿主专有工具一律由宿主自行构造，打包成 HostToolSet 经 ToolCentral.registerHost(_:) 注册；
//  AppAgent 不感知、不引用、不依赖。
//

import Foundation

/// Deployment intent supplied by the host at runtime.
///
/// This is deliberately independent from Swift's `DEBUG` flag and from the
/// Xcode configuration name. A Release build distributed internally can use
/// `.internalDevelopment`, while an online Release build can use `.online`.
public enum HostDeploymentProfile: String, Sendable {
    case disabled
    case internalDevelopment
    case online
}

/// Explicit host capability switches.
///
/// The profile describes where the build is used. The individual switches
/// decide which capabilities are actually exposed, so a Release build can
/// still enable selected internal tools without changing its compiler mode.
public struct HostToolsetConfiguration: Sendable {
    public var profile: HostDeploymentProfile
    public var runtimeToolsEnabled: Bool
    public var hotfixEnabled: Bool

    public init(
        profile: HostDeploymentProfile = .disabled,
        runtimeToolsEnabled: Bool = false,
        hotfixEnabled: Bool = false
    ) {
        self.profile = profile
        self.runtimeToolsEnabled = runtimeToolsEnabled
        self.hotfixEnabled = hotfixEnabled
    }
}

public enum HostToolset {

    /// Assemble tools from an explicit deployment profile and capability set.
    /// The profile is descriptive; the switches are authoritative.
    public static func makeTools(
        configuration: HostToolsetConfiguration,
        runtimeProvider: RuntimeInspectProvider? = nil,
        hotfixProvider: HotfixProvider? = nil,
        webInspectProvider: WebInspectProvider? = nil
    ) -> [any ToolProtocol] {
        guard configuration.profile != .disabled else {
            return []
        }
        return makeTools(
            runtimeProvider: runtimeProvider,
            hotfixProvider: hotfixProvider,
            webInspectProvider: webInspectProvider,
            runtimeToolsEnabled: configuration.runtimeToolsEnabled,
            hotfixEnabled: configuration.hotfixEnabled
        )
    }

    /// 依据开关与可用 provider 组装通用宿主能力工具。未启用或缺失 provider 的能力自动跳过。
    ///
    /// - Parameters:
    ///   - runtimeProvider: 宿主运行时内省实现；缺失则不提供 app_ui 与 app_runtime_inspect。
    ///   - hotfixProvider: 宿主热修复实现；缺失则不提供热修复工具。
    ///   - webInspectProvider: web / H5 内省实现；缺失时在 UIKit 平台自动用
    ///     `DefaultWebInspectProvider`（通用 WKWebView 实现），宿主零代码即可用。
    ///   - runtimeToolsEnabled: 界面操作 / 运行时内省 / web 内省总开关。
    ///   - hotfixEnabled: 热修复总开关。
    ///
    /// These switches are independent of Debug/Release. An internally
    /// distributed Release build can enable them explicitly; an online Release
    /// build should pass false unless the product deliberately supports them.
    public static func makeTools(
        runtimeProvider: RuntimeInspectProvider? = nil,
        hotfixProvider: HotfixProvider? = nil,
        webInspectProvider: WebInspectProvider? = nil,
        runtimeToolsEnabled: Bool = false,
        hotfixEnabled: Bool = false
    ) -> [any ToolProtocol] {
        var tools: [any ToolProtocol] = []

        if runtimeToolsEnabled, let runtimeProvider {
            tools.append(RuntimeInspectTool.ui(provider: runtimeProvider))
            tools.append(RuntimeInspectTool(provider: runtimeProvider))
        }
        if runtimeToolsEnabled {
            // WKWebView 的内容在独立进程，原生视图树看不到 DOM，所以 web 内省是独立一条链路。
            // 默认实现是通用的（发现 WKWebView + 独立 content world 里跑一次性 JS），
            // 宿主有自己的容器注册表时再注入自己的 provider 覆盖。
            if let webInspectProvider {
                tools.append(WebInspectTool(provider: webInspectProvider))
            } else {
                #if canImport(UIKit) && canImport(WebKit)
                tools.append(WebInspectTool(provider: DefaultWebInspectProvider.shared))
                #endif
            }
        }
        if hotfixEnabled, let hotfixProvider {
            tools.append(HotfixTool(provider: hotfixProvider))
        }
        return tools
    }
}
