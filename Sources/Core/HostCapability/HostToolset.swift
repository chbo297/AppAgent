//
//  HostToolset.swift
//  AppAgent — 宿主能力工具装配
//
//  按宿主注入的 provider 组装「运行时内省 / 热修复 / 消息捕获」这类通用宿主能力工具。
//  宿主拿到数组后自行注册到 ToolCentral（或通过 AIAgentProfile 暴露）。
//
//  ⚠️ 领域/业务能力不在此处：按「AppAgent 只做通用机制与协议，业务能力由宿主实现并注册」的
//  设计约束，地图能力（app_map_*）、宿主后台服务的补丁工具等宿主专有工具一律由宿主自行构造，
//  经 ToolCentral.register(_:) 注册进来即可，AppAgent 不感知、不引用、不依赖。
//

import Foundation

public enum HostToolset {

    /// 依据开关与可用 provider 组装通用宿主能力工具。未启用或缺失 provider 的能力自动跳过。
    ///
    /// - Parameters:
    ///   - runtimeProvider: 宿主运行时内省实现；缺失则不提供内省与消息捕获工具。
    ///   - hotfixProvider: 宿主热修复实现；缺失则不提供热修复工具。
    ///   - webInspectProvider: web / H5 内省实现；缺失时在 UIKit 平台自动用
    ///     `DefaultWebInspectProvider`（通用 WKWebView 实现），宿主零代码即可用。
    ///   - runtimeToolsEnabled: 运行时内省 / 消息捕获 / web 内省总开关（默认关，需宿主显式打开）。
    ///   - hotfixEnabled: 热修复总开关（默认关，需宿主显式打开）。
    public static func makeTools(
        runtimeProvider: RuntimeInspectProvider? = nil,
        hotfixProvider: HotfixProvider? = nil,
        webInspectProvider: WebInspectProvider? = nil,
        runtimeToolsEnabled: Bool = false,
        hotfixEnabled: Bool = false
    ) -> [any ToolProtocol] {
        var tools: [any ToolProtocol] = []

        if runtimeToolsEnabled, let runtimeProvider {
            tools.append(RuntimeInspectTool(provider: runtimeProvider))
            // 消息捕获诊断工具随运行时诊断能力一并开放。自包含（读写共享 NSUserDefaults 契约 +
            // 沙盒 JSONL），无需注入 provider；捕获通道默认全关，由本工具按需拨动。
            tools.append(HookCaptureTool())
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
