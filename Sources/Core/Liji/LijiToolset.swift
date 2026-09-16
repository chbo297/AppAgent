//
//  LijiToolset.swift
//  AppAgent — Liji 集成层
//
//  按 LijiConfig 的能力开关 + 已注入的 provider，组装 app agent 的通用集成工具集合
//  （liji_server 后台补丁、运行时内省、热修复）。宿主拿到数组后自行注册到 ToolCentral
//  （或通过 AIAgentProfile 暴露）。
//
//  ⚠️ 地图领域能力（app_map_*）不在此处：按「AppAgent 只做通用共用与协议、地图能力由宿主
//  百度地图实现」的设计约束，地图工具（Map*Tool）与其 provider 协议已迁至宿主
//  mapframework/Sources/AppAgentIntegration，由宿主自行构造并注册到 ToolCentral。
//

import Foundation

public enum LijiToolset {

    /// 依据配置与可用 provider 组装通用集成工具。未启用或缺失 provider 的能力自动跳过。
    public static func makeTools(
        config: LijiConfig,
        runtimeProvider: RuntimeInspectProvider? = nil,
        hotfixProvider: HotfixProvider? = nil,
        serverClient: LijiServerClient? = nil
    ) -> [any ToolProtocol] {
        var tools: [any ToolProtocol] = []

        if config.lijiServerEnabled {
            let client = serverClient ?? LijiServerClient(config: config)
            tools.append(LijiServerTool(client: client,
                                        hotfix: config.hotfixEnabled ? hotfixProvider : nil))
        }
        if config.runtimeToolsEnabled, let runtimeProvider {
            tools.append(RuntimeInspectTool(provider: runtimeProvider))
        }
        if config.hotfixEnabled, let hotfixProvider {
            tools.append(HotfixTool(provider: hotfixProvider))
        }
        return tools
    }
}
