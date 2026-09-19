//
//  AppAgentMarkdownTests.swift
//  AppAgentUITests
//
//  markdown 渲染的回归：块级结构（标题 / 列表 / 段落 / 代码块）必须有换行，
//  不能糊成一整段；GFM 表格要降级成读得懂的列表行。
//

#if canImport(UIKit)
import XCTest
@testable import AppAgent

final class AppAgentMarkdownTests: XCTestCase {

    private func render(_ markdown: String) -> String {
        AppAgentMarkdown.attributed(
            markdown,
            baseFont: .systemFont(ofSize: 15),
            color: .black
        ).string
    }

    func testBlocksKeepLineBreaks() {
        let rendered = render("""
        ### 标题

        正文一。

        - 甲
        - 乙
        """)

        XCTAssertEqual(rendered, "标题\n正文一。\n• 甲\n• 乙")
    }

    /// 有序列表的序号不能被解析器当成列表标记吃掉，两项也要各占一行。
    func testOrderedListKeepsItsNumbers() {
        let rendered = render("""
        1. 第一条
        2. 第二条
        """)

        // 前缀用不换行空格隔开（避免被当成列表标记），断言时还原成普通空格。
        let visible = rendered.replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertEqual(visible, "1. 第一条\n2. 第二条")
    }

    func testCodeBlockStaysOnItsOwnLines() {
        let rendered = render("""
        前一行

        ```swift
        let x = 1
        ```
        """)
        XCTAssertTrue(rendered.contains("前一行\n"))
        XCTAssertTrue(rendered.contains("let x = 1"))
    }

    /// 链接必须带着 `.link` 属性活下来：渲染时按 run 重建字符串很容易把它丢掉，
    /// 丢了就只剩一段蓝字、点不动。
    func testLinkKeepsItsURL() {
        let attributed = AppAgentMarkdown.attributed(
            "看 [文档](https://example.com/doc) 一节。",
            baseFont: .systemFont(ofSize: 15),
            color: .black
        )

        XCTAssertEqual(attributed.string, "看 文档 一节。")

        var found: URL?
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let url = value as? URL { found = url }
        }
        XCTAssertEqual(found, URL(string: "https://example.com/doc"))
    }

    /// 删除线在 `inlinePresentationIntent` 里，转换时不会自动落成属性，要自己补。
    func testStrikethroughBecomesAnAttribute() {
        let attributed = AppAgentMarkdown.attributed(
            "这是 ~~旧说法~~ 的更正。",
            baseFont: .systemFont(ofSize: 15),
            color: .black
        )

        var styles: [Int] = []
        attributed.enumerateAttribute(.strikethroughStyle,
                                      in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let raw = value as? Int { styles.append(raw) }
        }
        XCTAssertEqual(styles, [NSUnderlineStyle.single.rawValue])
    }

    /// 系统解析器不认 GFM 表格：必须降级成一行一个条目，而不是把各列拼在一起。
    func testTableDegradesToSeparateLines() {
        let rendered = render("""
        | 项目 | 用途 |
        | --- | --- |
        | LangChain.swift | Agent 抽象 |
        | swift-sdk | MCP 协议层 |
        """)

        XCTAssertEqual(rendered, """
        • 项目：LangChain.swift；用途：Agent 抽象
        • 项目：swift-sdk；用途：MCP 协议层
        """)
    }

    /// 普通段落里的换行不该被吃掉。
    func testPlainTextWithoutMarkdownSurvives() {
        let rendered = render("就一句普通的话。")
        XCTAssertEqual(rendered, "就一句普通的话。")
    }
}

#endif
