import Foundation
import XCTest
@testable import AppAgent

final class AssistantIdentityTests: XCTestCase {
    func testDefaultsProvideOneStaticXiaoLanIdentity() {
        let profile = AIAgentProfile()

        XCTAssertEqual(profile.promptBuilders.count, 1)
        XCTAssertEqual(profile.promptBuilders.first?.name, "identity")
        XCTAssertEqual(textSegments(profile), [profile.identity])
        XCTAssertTrue(profile.identity.hasPrefix("你是小蓝，由 AppAgent 运行在宿主应用「"))
        XCTAssertTrue(profile.identity.contains("内的 AI 助手"))
        XCTAssertTrue(profile.identity.contains("宿主提供的功能"))
        XCTAssertTrue(profile.identity.contains("多个对话会话"))
        XCTAssertTrue(profile.messageContextProviders.isEmpty)
    }

    func testAssistantAndHostNamesAreInjectable() {
        let profile = AIAgentProfile(assistantName: "小青", hostAppName: "测试应用")

        XCTAssertTrue(profile.identity.hasPrefix(
            "你是小青，由 AppAgent 运行在宿主应用「测试应用」内的 AI 助手。"
        ))
        XCTAssertFalse(profile.identity.contains("小蓝"))
        XCTAssertEqual(textSegments(profile), [profile.identity])
    }

    func testBlankAssistantNameFallsBackToXiaoLan() {
        for name in ["", " \n\t"] {
            let profile = AIAgentProfile(assistantName: name, hostAppName: "测试应用")
            XCTAssertTrue(profile.identity.hasPrefix("你是小蓝，"))
        }
    }

    func testExplicitIdentityCompletelyOverridesDefaultAndEnvironment() {
        let identity = "  你是自定义助理，只遵循宿主指定的角色。\n"
        let profile = AIAgentProfile(
            identity: identity,
            assistantName: "不应出现的名字",
            hostAppName: "不应出现的宿主"
        )

        XCTAssertEqual(profile.identity, identity)
        XCTAssertEqual(textSegments(profile), [identity])
        XCTAssertEqual(profile.promptBuilders.map(\.name), ["identity"])
        XCTAssertFalse(profile.identity.contains("小蓝"))
        XCTAssertFalse(profile.identity.contains("AppAgent"))
        XCTAssertFalse(profile.identity.contains("不应出现"))
    }

    func testAdditionalBuildersAloneKeepDefaultIdentityFirst() {
        let rules = ["Be concise and helpful.", "If unsure, say so honestly."]
        let profile = AIAgentProfile(
            additionalPromptBuilders: rules.map { PromptBuilder($0) }
        )

        XCTAssertTrue(profile.identity.hasPrefix("你是小蓝，"))
        XCTAssertEqual(textSegments(profile), [profile.identity] + rules)
        XCTAssertEqual(profile.promptBuilders.filter { $0.name == "identity" }.count, 1)
        let combined = textSegments(profile).joined(separator: "\n")
        XCTAssertEqual(combined.components(separatedBy: "你是小蓝").count - 1, 1)
        XCTAssertTrue(profile.messageContextProviders.isEmpty)
    }

    func testEmptyIdentityWithExtrasStillUsesDefault() {
        let profile = AIAgentProfile(
            identity: "",
            hostAppName: "测试应用",
            additionalPromptBuilders: [PromptBuilder("保留这条规则。")]
        )

        XCTAssertTrue(profile.identity.hasPrefix("你是小蓝，"))
        XCTAssertEqual(textSegments(profile), [profile.identity, "保留这条规则。"])
    }

    func testExplicitIdentityWithExtrasDoesNotDuplicateIdentity() {
        let identity = "你是专门的阅读助理。"
        let profile = AIAgentProfile(
            identity: identity,
            additionalPromptBuilders: [PromptBuilder("保持简洁。")]
        )

        XCTAssertEqual(profile.identity, identity)
        XCTAssertEqual(textSegments(profile), [identity, "保持简洁。"])
        XCTAssertEqual(profile.promptBuilders.filter { $0.name == "identity" }.count, 1)
        XCTAssertFalse(textSegments(profile).joined().contains("小蓝"))
    }

    func testPrimaryInitializerRemainsFullyExplicit() {
        let profile = AIAgentProfile(
            promptBuilders: [PromptBuilder("host", prompt: "仅使用宿主规则。")]
        )
        XCTAssertEqual(profile.identity, "")
        XCTAssertEqual(profile.promptBuilders.map(\.name), ["host"])
        XCTAssertEqual(textSegments(profile), ["仅使用宿主规则。"])

        let empty = AIAgentProfile(promptBuilders: [])
        XCTAssertEqual(empty.identity, "")
        XCTAssertTrue(empty.promptBuilders.isEmpty)
    }

    func testHostNameResolutionPrefersOverrideThenDisplayNameThenBundleName() {
        XCTAssertEqual(AIAgentProfile.resolveHostAppName(
            "指定宿主", bundleDisplayName: "显示名称", bundleName: "BundleName"
        ), "指定宿主")
        XCTAssertEqual(AIAgentProfile.resolveHostAppName(
            nil, bundleDisplayName: "显示名称", bundleName: "BundleName"
        ), "显示名称")
        XCTAssertEqual(AIAgentProfile.resolveHostAppName(
            nil, bundleDisplayName: nil, bundleName: "BundleName"
        ), "BundleName")
        XCTAssertEqual(AIAgentProfile.resolveHostAppName(
            nil, bundleDisplayName: nil, bundleName: nil
        ), "宿主应用")
    }

    func testHostNameResolutionTrimsNamesAndSkipsBlankCandidates() {
        XCTAssertEqual(AIAgentProfile.resolveHostAppName(
            " 指定宿主 \n", bundleDisplayName: "显示名称", bundleName: "BundleName"
        ), "指定宿主")
        XCTAssertEqual(AIAgentProfile.resolveHostAppName(
            " \n", bundleDisplayName: " 显示名称 ", bundleName: "BundleName"
        ), "显示名称")
        XCTAssertEqual(AIAgentProfile.resolveHostAppName(
            "", bundleDisplayName: "\t", bundleName: " BundleName\n"
        ), "BundleName")
        XCTAssertEqual(AIAgentProfile.resolveHostAppName(
            "\n", bundleDisplayName: "", bundleName: " \t"
        ), "宿主应用")
    }

    func testDefaultHostUsesMainBundleMetadata() {
        let expectedHost = ["CFBundleDisplayName", "CFBundleName"]
            .compactMap { Bundle.main.object(forInfoDictionaryKey: $0) as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "宿主应用"

        for hostName: String? in [nil, "", " \n"] {
            let profile = AIAgentProfile(hostAppName: hostName)
            XCTAssertTrue(profile.identity.contains("宿主应用「\(expectedHost)」"))
        }
    }

    func testIdentityIsStableAndDoesNotAdvertiseUnavailableToolsOrExpandScope() {
        let profile = AIAgentProfile(
            hostAppName: "测试应用",
            registerBuiltInTools: false,
            disabledBuiltInTools: ["session_manage", "session_search"]
        )
        let other = AIAgentProfile(hostAppName: "测试应用")

        XCTAssertEqual(textSegments(profile), textSegments(other))
        XCTAssertTrue(profile.identity.contains("当前实际可用的工具"))
        XCTAssertTrue(profile.identity.contains("仅在相应会话工具可用时"))
        XCTAssertTrue(profile.identity.contains("不预载其他会话历史"))
        XCTAssertTrue(profile.identity.contains("不扩大 SDK 运行时访问范围"))
        XCTAssertTrue(profile.identity.contains("工具范围与授权"))
        XCTAssertFalse(profile.identity.contains("session_manage"))
        XCTAssertFalse(profile.identity.contains("session_search"))
        XCTAssertTrue(profile.messageContextProviders.isEmpty)
    }

    func testSessionToolPromptsDescribeOnDemandHistoryAndArchiveOnlyDeletion() throws {
        let prompts = AIAgentProfile.defaultBuiltInToolPrompts
        let search = try XCTUnwrap(prompts["session_search"])
        XCTAssertTrue(search.contains("only when needed"))
        XCTAssertTrue(search.contains("Do not preload"))

        let manage = try XCTUnwrap(prompts["session_manage"])
        XCTAssertTrue(manage.contains("AppAgent conversations"))
        XCTAssertTrue(manage.contains("list/read/create/merge/archive/restore"))
        XCTAssertTrue(manage.contains("as available in the current tool schema"))
        XCTAssertTrue(manage.contains("'delete' means archive"))
        XCTAssertTrue(manage.contains("No permanent deletion via tools"))
        XCTAssertTrue(manage.contains("only the user can purge in the UI"))
    }

    private func textSegments(
        _ profile: AIAgentProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String] {
        profile.promptBuilders.map { builder in
            guard case .text(let text) = builder.content else {
                XCTFail("Identity tests expect static builders, not per-session resolvers.", file: file, line: line)
                return ""
            }
            return text
        }
    }
}
