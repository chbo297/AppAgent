//
//  LijiConfig.swift
//  AppAgent — Liji 集成层
//
//  「app agent」（＝本工程 AppAgent）在百度地图内的运行配置。
//  默认填入 OneAPI 网关；允许宿主/用户覆盖 endpoint / apiKey / model / protocol。
//

import Foundation

/// app agent 在百度地图中的整体配置。可 Codable 持久化（apiKey 建议单独存 Keychain）。
public struct LijiConfig: Sendable, Codable {

    // MARK: 大模型 Provider 配置
    /// Provider 逻辑名（注册到 ModelProviderCentral 用）。
    public var providerName: String
    /// 使用的 API 协议。当前实现支持 `.openaiCompletions` 与 `.anthropicMessages`。
    public var apiProtocol: APIProtocol
    /// 接口地址（含 /v1）。OneAPI 默认 `https://oneapi-comate.baidu-int.com/v1`。
    public var baseURL: String
    /// API Key（运行时注入；不建议随对象长期持久化，宜存 Keychain）。
    public var apiKey: String
    /// 选用模型 id。
    public var model: String
    /// 附加请求头。OneAPI 需要 `comate_custom_header`。
    public var customHeaders: [String: String]
    /// 模型上下文与最大输出，用于构造 ModelSpec。
    public var contextWindow: Int
    public var maxTokens: Int

    // MARK: liji_server（后台补丁服务）
    /// liji_server 基址（生产走零信任网关 `https://liji.n.baidu.com`），仅用于登录/绑定。
    public var lijiServerBaseURL: String
    /// 登录绑定后拿到的直连端点（"http://ip:port"），API 调用走这里以绕过零信任网关。
    public var directBaseURL: String?
    /// 设备 cuid（客户端上报）。
    public var cuid: String?
    /// 登录绑定后签发的 client_token（直连鉴权用；建议存 Keychain）。
    public var clientToken: String?
    /// 本地联调时透传的 dev 用户名（仅当服务端 dev_auth 开启时生效；生产留空）。
    public var devUser: String?

    // MARK: 能力开关（在百度地图中集中配置）
    /// 是否开放「运行时内省」工具（UI 层级 / 类·方法·属性 / 方法调用）。默认关闭。
    public var runtimeToolsEnabled: Bool
    /// 是否开放「热修复」工具（下发并应用 JS 补丁）。默认关闭。
    public var hotfixEnabled: Bool
    /// 是否开放 liji_server 需求提交工具。默认开启。
    public var lijiServerEnabled: Bool

    public init(
        providerName: String = "oneapi",
        apiProtocol: APIProtocol = .openaiCompletions,
        baseURL: String = LijiConfig.oneAPIBaseURL,
        apiKey: String = "",
        model: String = "gpt-5.6-sol",
        customHeaders: [String: String] = LijiConfig.defaultOneAPIHeaders,
        contextWindow: Int = 200_000,
        maxTokens: Int = 8192,
        lijiServerBaseURL: String = "https://liji.n.baidu.com",
        devUser: String? = nil,
        runtimeToolsEnabled: Bool = false,
        hotfixEnabled: Bool = false,
        lijiServerEnabled: Bool = true
    ) {
        self.providerName = providerName
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.customHeaders = customHeaders
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.lijiServerBaseURL = lijiServerBaseURL
        self.devUser = devUser
        self.runtimeToolsEnabled = runtimeToolsEnabled
        self.hotfixEnabled = hotfixEnabled
        self.lijiServerEnabled = lijiServerEnabled
    }

    // MARK: OneAPI 默认值
    public static let oneAPIBaseURL = "https://oneapi-comate.baidu-int.com/v1"
    /// 注意：`comate_custom_header` 的 username/source 由宿主按需覆盖。
    public static let defaultOneAPIHeaders: [String: String] = [
        "comate_custom_header": "{\"username\":\"liji\",\"source\":\"appagent\"}"
    ]

    /// 百度地图默认配置：OneAPI + 默认模型，用户可再覆盖 apiKey。
    public static func baiduMapDefault() -> LijiConfig { LijiConfig() }

    /// 模型选择引用（"providerName/modelId"）。
    public var modelRef: String { "\(providerName)/\(model)" }
}
