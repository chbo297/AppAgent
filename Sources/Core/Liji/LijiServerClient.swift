//
//  LijiServerClient.swift
//  OpenAPP — Liji 集成层
//
//  访问 liji_server（后台补丁服务）。生产环境请求发往零信任网关域名，
//  身份由网关注入 X-Zt-Authorization；本地联调可用 devUser → X-Dev-User。
//

import Foundation

// MARK: - DTOs（对应 liji_server 的响应，snake_case 由解码器转换）

public struct LijiPatchDTO: Sendable, Codable {
    public let id: String
    public let name: String
    public let applyMode: String
    public let jsSha256: String
    public let downloadUrl: String
}

public struct LijiRequirementDTO: Sendable, Codable {
    public let id: String
    public let taskId: String
    public let prompt: String
    public let status: String
    public let summary: String
    public let error: String
    public let iteration: Int
    public let patch: LijiPatchDTO?
}

public struct LijiTaskDTO: Sendable, Codable {
    public let id: String
    public let title: String
    public let requirements: [LijiRequirementDTO]
}

public struct LijiShareDTO: Sendable, Codable {
    public let token: String
    public let shareUrl: String
    public let qrUrl: String
}

public struct LijiGrantDTO: Sendable, Codable {
    public let token: String
    public let title: String
    public let note: String
    public let owner: String
    public let enabled: Bool
    public let patch: LijiPatchDTO?
}

public struct LijiDownloadedPatch: Sendable {
    public let javascript: String
    public let applyMode: String
    public let sha256: String
}

public enum LijiServerError: Error, Sendable {
    case badURL
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)
}

/// liji_server 客户端。所有方法 async，iOS 13 兼容（continuation 包装 dataTask）。
public final class LijiServerClient: @unchecked Sendable {
    private let baseURL: String
    private let devUser: String?
    private let cuid: String?
    private let clientToken: String?
    private let session: URLSession

    public init(baseURL: String, devUser: String? = nil, cuid: String? = nil,
                clientToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.devUser = devUser
        self.cuid = cuid
        self.clientToken = clientToken
        self.session = session
    }

    /// 由配置构造：API 调用优先走直连端点（绕过零信任网关），带 cuid + client_token 鉴权。
    public convenience init(config: LijiConfig) {
        self.init(baseURL: config.directBaseURL ?? config.lijiServerBaseURL,
                  devUser: config.devUser, cuid: config.cuid, clientToken: config.clientToken)
    }

    // MARK: 请求基建

    private func makeRequest(_ path: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw LijiServerError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let devUser { req.setValue(devUser, forHTTPHeaderField: "X-Dev-User") }
        // 直连鉴权头（绕过零信任网关时使用）
        if let cuid { req.setValue(cuid, forHTTPHeaderField: "X-Liji-Cuid") }
        if let clientToken { req.setValue(clientToken, forHTTPHeaderField: "X-Liji-Token") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    cont.resume(throwing: LijiServerError.transport(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: LijiServerError.transport("no HTTP response"))
                    return
                }
                cont.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            throw LijiServerError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LijiServerError.decoding("\(error)")
        }
    }

    // MARK: API

    /// 提交需求（异步生成补丁）。
    public func submitRequirement(prompt: String, runtimeContext: String = "", taskId: String? = nil) async throws -> LijiRequirementDTO {
        var body: [String: Any] = ["prompt": prompt, "runtime_context": runtimeContext]
        if let taskId { body["task_id"] = taskId }
        return try await decodeJSON(LijiRequirementDTO.self, try makeRequest("/api/v1/tasks", method: "POST", body: body))
    }

    /// 查询单个需求状态。
    public func requirementStatus(id: String) async throws -> LijiRequirementDTO {
        try await decodeJSON(LijiRequirementDTO.self, try makeRequest("/api/v1/requirements/\(id)", method: "GET"))
    }

    /// 我的任务与需求列表。
    public func listTasks() async throws -> [LijiTaskDTO] {
        try await decodeJSON([LijiTaskDTO].self, try makeRequest("/api/v1/tasks", method: "GET"))
    }

    /// 迭代重生成。
    public func regenerate(requirementId: String, prompt: String? = nil, runtimeContext: String? = nil) async throws -> LijiRequirementDTO {
        var body: [String: Any] = [:]
        if let prompt { body["prompt"] = prompt }
        if let runtimeContext { body["runtime_context"] = runtimeContext }
        return try await decodeJSON(LijiRequirementDTO.self,
            try makeRequest("/api/v1/requirements/\(requirementId)/regenerate", method: "POST", body: body.isEmpty ? nil : body))
    }

    /// 端上回写状态（applied / disabled）。
    public func updateStatus(requirementId: String, status: String) async throws -> LijiRequirementDTO {
        try await decodeJSON(LijiRequirementDTO.self,
            try makeRequest("/api/v1/requirements/\(requirementId)", method: "PATCH", body: ["status": status]))
    }

    /// 下载补丁 JS，返回内容与 apply_mode（读响应头）。
    public func downloadPatch(patchId: String) async throws -> LijiDownloadedPatch {
        let (data, http) = try await perform(try makeRequest("/api/v1/patches/\(patchId)", method: "GET"))
        guard (200..<300).contains(http.statusCode) else {
            throw LijiServerError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let js = String(data: data, encoding: .utf8) ?? ""
        let mode = http.value(forHTTPHeaderField: "X-Patch-Apply-Mode") ?? "restart"
        let sha = http.value(forHTTPHeaderField: "X-Patch-Sha256") ?? ""
        return LijiDownloadedPatch(javascript: js, applyMode: mode, sha256: sha)
    }

    /// 为补丁生成分享（二维码 + token）。
    public func share(patchId: String) async throws -> LijiShareDTO {
        try await decodeJSON(LijiShareDTO.self, try makeRequest("/api/v1/patches/\(patchId)/share", method: "POST"))
    }

    /// 领取他人分享。
    public func claim(token: String) async throws -> LijiGrantDTO {
        try await decodeJSON(LijiGrantDTO.self, try makeRequest("/api/v1/shares/\(token)/claim", method: "POST"))
    }

    /// 分享给我的列表。
    public func granted() async throws -> [LijiGrantDTO] {
        try await decodeJSON([LijiGrantDTO].self, try makeRequest("/api/v1/shares/granted", method: "GET"))
    }

    /// 开/关某分享补丁。
    public func toggleGrant(token: String, enabled: Bool) async throws -> LijiGrantDTO {
        try await decodeJSON(LijiGrantDTO.self,
            try makeRequest("/api/v1/shares/\(token)/toggle", method: "PATCH", body: ["enabled": enabled]))
    }

    // MARK: 登录绑定 / 服务发现（走网关基址）

    /// 绑定当前设备（经零信任网关鉴权识别 uuapname），签发 client_token + 直连端点。
    public func bind(cuid: String, enc: String? = nil) async throws -> LijiBindDTO {
        var body: [String: Any] = ["cuid": cuid]
        if let enc { body["enc"] = enc }
        return try await decodeJSON(LijiBindDTO.self, try makeRequest("/auth/bind", method: "POST", body: body))
    }

    /// 获取最新直连端点（公开）。
    public func endpoints() async throws -> LijiEndpointsDTO {
        try await decodeJSON(LijiEndpointsDTO.self, try makeRequest("/auth/endpoints", method: "GET"))
    }
}

public struct LijiBindDTO: Sendable, Codable {
    public let token: String
    public let uuapname: String
    public let cuid: String
    public let expiresAt: Double
    public let endpoints: [String]
    public let port: Int
}

public struct LijiEndpointsDTO: Sendable, Codable {
    public let endpoints: [String]
    public let port: Int
}
