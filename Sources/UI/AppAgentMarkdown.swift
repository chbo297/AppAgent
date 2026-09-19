//
//  AppAgentMarkdown.swift
//  AppAgentUI
//
//  把 agent 的回复按 markdown 渲染（标题 / 粗体 / 斜体 / 行内代码 / 代码块 / 列表 /
//  引用 / 链接），而不是把 `###`、`|---|`、`[x](url)` 原样显示给用户。
//
//  用系统 `AttributedString(markdown:)`（iOS 15+，本仓最低版本已升到 15）解析，
//  自己只做一层收尾：把基础字体与颜色按语义施加到每个 run——系统给的字号是相对
//  preferredFont 的，直接塞进气泡会与其它消息不协调。
//
//  写属性一律走 `NSAttributedString.Key`，不用 `attributed[range].font` 这类动态查找：
//  同一个属性名在 UIKit 与 SwiftUI 两个 attribute scope 里都存在（例如删除线），
//  动态查找会挑中 SwiftUI 那个，而本 target 不链接 SwiftUI —— 直接变成链接错误。
//
//  另一个坑：`NSAttributedString(AttributedString)` 不认块级结构。`AttributedString`
//  把标题/列表/段落记在 `presentationIntent` 里，转成 NSAttributedString 后这些元数据
//  不产生任何换行，整篇会糊成一段。而且只有**空行分隔**的块才会被解析成不同块，
//  相邻的列表项（`- 甲\n- 乙`）会并进同一个块，光靠 intent 分不开。
//  所以解析前先做一遍块级规整：给每个块之间补空行，列表项/表格行自带「• 」前缀，
//  这样每块都是独立段落、各占一行；解析后仍从 intent 取标题字号与代码等宽。
//

#if canImport(UIKit)
import UIKit

enum AppAgentMarkdown {

    /// 把 markdown 文本渲染成带样式的富文本。
    ///
    /// - Parameters:
    ///   - markdown: 原始文本。
    ///   - baseFont: 正文字体（标题、代码在此基础上派生）。
    ///   - color: 正文颜色。
    static func attributed(_ markdown: String, baseFont: UIFont, color: UIColor) -> NSAttributedString {
        let source = normalizeBlocks(markdown)
        let plain = { () -> NSAttributedString in
            NSAttributedString(string: source, attributes: [
                .font: baseFont,
                .foregroundColor: color
            ])
        }

        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return plain()
        }

        let result = NSMutableAttributedString()
        var lastBlockIdentity: Int?
        var isFirstBlock = true

        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.last?.identity

            if identity != lastBlockIdentity {
                if !isFirstBlock {
                    result.append(NSAttributedString(string: "\n"))
                }
                lastBlockIdentity = identity
                isFirstBlock = false
            }

            result.append(fragment(parsed[run.range], run: run, components: components,
                                  baseFont: baseFont, color: color))
        }

        return result
    }

    // MARK: - 单个 run

    /// 把一个 run 转成富文本片段。
    ///
    /// 先走 `NSAttributedString(AttributedString(...))` 把解析器给的属性带过来——尤其是
    /// 链接（`[x](url)` 的 `.link`），自己重建字符串会把它丢掉，链接就点不动了。
    /// 然后只覆盖字体与正文色（解析出来的字号是相对 preferredFont 的，见文件头注释）。
    /// 删除线是 `inlinePresentationIntent` 里的语义、转换时不会落成属性，补一笔。
    private static func fragment(
        _ slice: AttributedSubstring,
        run: AttributedString.Runs.Run,
        components: [PresentationIntent.IntentType],
        baseFont: UIFont,
        color: UIColor
    ) -> NSAttributedString {
        let piece = NSMutableAttributedString(attributedString: NSAttributedString(AttributedString(slice)))
        let whole = NSRange(location: 0, length: piece.length)
        guard whole.length > 0 else { return piece }

        piece.addAttributes([
            .font: font(for: run, components: components, base: baseFont),
            .foregroundColor: color
        ], range: whole)

        if run.inlinePresentationIntent?.contains(.strikethrough) == true {
            piece.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: whole)
        }
        return piece
    }

    // MARK: - 块级规整

    /// 把 markdown 规整成「一块一段」：
    ///
    /// - 标题、列表项、表格行、代码围栏前后各补一个空行，保证被解析成独立块；
    /// - 列表项自己带上「• 」/「1. 」前缀（字面量），不再依赖列表语义；
    /// - GFM 表格改写成「表头：值」的条目行——系统解析器不认表格，否则各列会直接拼在一起。
    static func normalizeBlocks(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var out: [String] = []
        var index = 0
        var inFence = false

        func blank() {
            if out.last != "" { out.append("") }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                blank()
                inFence.toggle()
                out.append(line)
                index += 1
                if !inFence { blank() }
                continue
            }
            if inFence {
                out.append(line)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                blank()
                index += 1
                continue
            }

            // 表格：| a | b |  +  分隔行  +  若干数据行
            if isTableRow(line), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                let headers = cells(of: line)
                var row = index + 2
                while row < lines.count, isTableRow(lines[row]) {
                    let pairs = zip(headers, cells(of: lines[row])).map { "\($0)：\($1)" }
                    blank()
                    out.append("• " + (pairs.isEmpty ? cells(of: lines[row]).joined(separator: " ") : pairs.joined(separator: "；")))
                    row += 1
                }
                index = row
                continue
            }

            if let item = listItemText(of: line) {
                blank()
                out.append(item)
                index += 1
                continue
            }

            if isHeading(line) {
                blank()
                out.append(line)
                blank()
                index += 1
                continue
            }

            out.append(line)
            index += 1
        }

        return out.joined(separator: "\n")
    }

    /// 列表项 → 带字面量前缀的单行。
    ///
    /// 前缀刻意用不成 markdown 标记的形式：无序用「• 」（`-`/`*` 会被解析成列表），
    /// 有序序号后面跟不换行空格而不是普通空格（`1. ` 同样会被当成列表标记吃掉，
    /// 而列表项之间会并进同一个块，就没法逐行分开了）。渲染出来看不出差别。
    private static func listItemText(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var rest = Substring(trimmed)
        var prefix: String?

        if let first = rest.first, "-*+•".contains(first) {
            let after = rest.dropFirst()
            if after.first == " " {
                prefix = "• "
                rest = after.dropFirst()
            }
        } else {
            let digits = rest.prefix { $0.isNumber }
            let afterDigits = rest.dropFirst(digits.count)
            if !digits.isEmpty, let marker = afterDigits.first, marker == "." || marker == ")" {
                let after = afterDigits.dropFirst()
                if after.first == " " {
                    prefix = "\(digits).\u{00A0}"   // NBSP：读起来一样，但不再是列表标记
                    rest = after.dropFirst()
                }
            }
        }

        guard let prefix else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return prefix + text
    }

    private static func isHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        return trimmed.dropFirst(hashes.count).hasPrefix(" ")
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 2 && trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
    }

    /// 分隔行：`| --- | --- |`
    private static func isTableSeparator(_ line: String) -> Bool {
        let body = cells(of: line)
        guard !body.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "-: ")
        return body.allSatisfy { cell in
            !cell.isEmpty
                && cell.contains("-")
                && cell.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    private static func cells(of line: String) -> [String] {
        line.trimmingCharacters(in: .whitespaces)
            .dropFirst()
            .dropLast()
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - 字号派生

    private static func font(
        for run: AttributedString.Runs.Run,
        components: [PresentationIntent.IntentType],
        base: UIFont
    ) -> UIFont {
        var font = base

        for component in components {
            switch component.kind {
            case .header(let level):
                font = headerFont(level: level, base: base)
            case .codeBlock:
                font = monospacedFont(base: base)
            default:
                break
            }
        }

        if let inline = run.inlinePresentationIntent {
            if inline.contains(.code) {
                font = monospacedFont(base: font)
            }
            if inline.contains(.stronglyEmphasized) {
                font = font.bolded()
            }
            if inline.contains(.emphasized) {
                font = font.italicized()
            }
        }

        return font
    }

    private static func headerFont(level: Int, base: UIFont) -> UIFont {
        // h1..h4 递减；更深层级不再缩小，避免正文读不清。
        let scale: CGFloat
        switch level {
        case 1: scale = 1.45
        case 2: scale = 1.3
        case 3: scale = 1.15
        default: scale = 1.05
        }
        return UIFont.systemFont(ofSize: (base.pointSize * scale).rounded(), weight: .semibold)
    }

    private static func monospacedFont(base: UIFont) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.95, weight: .regular)
    }
}

private extension UIFont {
    /// 加粗：保留字体家族（等宽仍是等宽），只补 bold trait。
    func bolded() -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        traits.insert(.traitBold)
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else {
            return UIFont.systemFont(ofSize: pointSize, weight: .semibold)
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    func italicized() -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

#endif
