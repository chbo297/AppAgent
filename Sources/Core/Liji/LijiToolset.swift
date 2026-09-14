//
//  LijiToolset.swift
//  AppAgent — Liji 集成层
//
//  按 LijiConfig 的能力开关 + 已注入的 provider，组装 app agent 在百度地图中的工具集合。
//  宿主拿到数组后自行注册到 ToolCentral（或通过 AIAgentProfile 暴露）。
//

import Foundation

public enum LijiToolset {

    /// 依据配置与可用 provider 组装工具。未启用或缺失 provider 的能力自动跳过。
    public static func makeTools(
        config: LijiConfig,
        runtimeProvider: RuntimeInspectProvider? = nil,
        hotfixProvider: HotfixProvider? = nil,
        serverClient: LijiServerClient? = nil,
        drawProvider: MapDrawProvider? = nil
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
        // 图区绘制作为 agent 能力：注入 provider 即开放（默认地图能力）
        if let drawProvider {
            tools.append(MapDrawTool(provider: drawProvider))
        }
        return tools
    }
}
