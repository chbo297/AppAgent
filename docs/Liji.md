# Liji 集成层（app agent × 百度地图 × liji_server）

> 本工程 **AppAgent 即「app agent」**。`liji` 分支在 Core 之上新增 `Sources/Core/Liji/`，
> 让 app agent 在百度地图内：用 OneAPI 跑大模型、把地图与运行时能力当工具、
> 需求不够本地实现时发给 liji_server 生成 JS 热修复补丁并应用/分享。

## 组成

```
Sources/Core/Liji/
  LijiConfig.swift            运行配置（默认 OneAPI；可配 endpoint/apiKey/model/protocol + 能力开关）
  LijiProviderFactory.swift   由配置构造 ModelProvider（复用通用 AnthropicProvider 的多协议分派）
  LijiServerClient.swift      访问 liji_server（提交/查询/下载/分享/领取/开关），iOS13 兼容
  LijiToolset.swift           按开关+provider 组装工具集合
  Providers/
    RuntimeInspectProvider.swift  宿主实现：UI层级/类·方法·属性/取值/反射调用
    HotfixProvider.swift          宿主实现：应用/开关/列举/移除命名 JS 补丁槽
  Tools/
    LijiServerTool.swift      liji_server：submit/status/list/apply/share/granted/toggle
    RuntimeInspectTool.swift  app_runtime_inspect（默认关，需 runtimeToolsEnabled + provider）
    HotfixTool.swift          app_hotfix（默认关，需 hotfixEnabled + provider）
```

## 协议支持

- 已实现：`.openaiCompletions`（OneAPI 默认走此协议）、`.anthropicMessages`。
- OneAPI 默认：`https://oneapi-comate.baidu-int.com/v1` + `comate_custom_header`，模型 `gpt-5.6-sol`。
- 待扩展：`.openaiResponses`（provider 目前 throws；需补 mapper + SSE 解析）。

## 宿主（百度地图）接入示例

```swift
import AppAgent

// 1) 配置：默认 OneAPI，用户可覆盖 apiKey / 打开能力开关
var config = LijiConfig.baiduMapDefault()
config.apiKey = KeychainStore.oneAPIKey()          // 用户在设置页配置
config.runtimeToolsEnabled = RemoteConfig.bool("liji_runtime_tools")
config.hotfixEnabled = RemoteConfig.bool("liji_hotfix")

// 2) Provider + Policy
let (provider, policy) = LijiProviderFactory.makeProviderAndPolicy(from: config)
await ModelProviderCentral.default.register(name: provider.name, provider: provider)

// 3) 工具：地图能力用 AppAgent 既有的 AppАction/AppNavigation/AppState provider（由地图侧实现）；
//    运行时/热修复/后台服务用 Liji provider。
let tools = LijiToolset.makeTools(
    config: config,
    runtimeProvider: MapRuntimeInspector(),   // 地图侧实现（ObjC runtime + keyWindow）
    hotfixProvider: BMBandageHotfixAdapter(),  // 地图侧实现（增强版 BMBandage）
    serverClient: LijiServerClient(config: config)
)
// 注册 tools 到 ToolCentral（或通过 AIAgentProfile 暴露）；地图能力工具单独注册

// 4) 创建 agent + overlay（见 README「UIKit Overlay」）
```

## 安全

- apiKey 走 Keychain，不随 LijiConfig 长期落盘。
- 运行时内省 / 热修复默认关闭，仅测试包 + 配置开启；本包不上架 AppStore。
- 生产请求发往 `liji.n.baidu.com`，零信任网关注入身份；本地联调用 `config.devUser`。
