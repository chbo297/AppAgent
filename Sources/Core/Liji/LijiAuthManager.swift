//
//  LijiAuthManager.swift
//  AppAgent — Liji 集成层
//
//  登录绑定与直连端点管理的纯逻辑助手（可 swift build 验证）。
//
//  正式登录流程在宿主壳浏览器（WKWebView）里完成：加载 `/auth/login`（经零信任网关，
//  网关为该 web 上下文注入 JWT），页面 JS 调 `/auth/bind` 拿到 LijiBindDTO 回传 native。
//  native 用 `applyBindResult` 把结果并入配置，之后 API 走直连端点（绕过网关）。
//

import Foundation

public enum LijiAuthManager {

    /// 把壳浏览器回传的绑定结果并入配置：设置 cuid / clientToken / directBaseURL。
    public static func applyBindResult(_ dto: LijiBindDTO, to config: LijiConfig) -> LijiConfig {
        var updated = config
        updated.cuid = dto.cuid
        updated.clientToken = dto.token
        if let ep = dto.endpoints.first {
            updated.directBaseURL = normalizeEndpoint(ep)
        }
        return updated
    }

    /// 刷新最新直连端点（`/auth/endpoints` 公开，可用直连或网关基址访问）。
    /// 返回更新后的配置（directBaseURL 指向最新端点）。
    public static func refreshEndpoints(config: LijiConfig) async throws -> LijiConfig {
        let base = config.directBaseURL ?? config.lijiServerBaseURL
        let client = LijiServerClient(baseURL: base, devUser: config.devUser,
                                      cuid: config.cuid, clientToken: config.clientToken)
        let dto = try await client.endpoints()
        var updated = config
        if let ep = dto.endpoints.first {
            updated.directBaseURL = normalizeEndpoint(ep)
        }
        return updated
    }

    /// 仅供本地联调：用 devUser 直接绑定（生产请走壳浏览器 + 网关）。
    public static func devBind(config: LijiConfig, cuid: String) async throws -> LijiConfig {
        let client = LijiServerClient(baseURL: config.lijiServerBaseURL, devUser: config.devUser)
        let dto = try await client.bind(cuid: cuid)
        return applyBindResult(dto, to: config)
    }

    static func normalizeEndpoint(_ ep: String) -> String {
        ep.hasPrefix("http://") || ep.hasPrefix("https://") ? ep : "http://\(ep)"
    }
}
