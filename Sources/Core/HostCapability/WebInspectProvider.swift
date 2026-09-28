//
//  WebInspectProvider.swift
//  AppAgent — 宿主能力层
//
//  向 app agent 暴露「H5 / WKWebView 内省」能力：列出容器、读运行时 DOM 与 computed style、
//  判定元素为何不可见、按屏幕点反查节点、读页面源码与资源、执行 JS、采集 web 侧 console 输出。
//
//  为什么单独一套而不并进 RuntimeInspectProvider：WKWebView 的内容跑在独立进程，原生视图树到
//  WKWebView 就断了（下面只有 WKScrollView / WKContentView，没有任何 DOM 语义）。DOM 只能经
//  evaluateJavaScript 拿，是另一条完全不同的链路。
//
//  默认实现 `DefaultWebInspectProvider` 已经覆盖通用 WKWebView 场景，宿主零代码即可用；
//  宿主若有自己的容器注册表（如百度地图的壳浏览器 / Cordova / EmbedNa 容器），可实现本协议
//  接管 `targets()` 以给出 containerType、comID 等业务信息。
//

import Foundation

public protocol WebInspectProvider: Sendable {

    /// 当前活着的 web 容器清单（JSON 字符串）。
    func targets() async -> String

    /// 语义锚点 DOM 摘要：只列有文本 / 可交互 / 有 id / 面积够大的节点，大子树折叠成 `⊞ N nodes`。
    /// `webviewId` 为 nil 时取默认容器（可见且面积最大的那个）。
    func domSummary(webviewId: String?, path: String?, maxNodes: Int) async -> String

    /// 单节点详情：盒模型、computed 子集、scroll/client 尺寸、祖先链与约束宽度的祖先。
    /// `selector` 优先于 `path`。
    func domQuery(webviewId: String?, selector: String?, path: String?) async -> String

    /// 「为何没展示」的归因：display / visibility / opacity / 零尺寸 / 祖先裁切 / 视口外 / 被遮挡。
    func whyHidden(webviewId: String?, selector: String?, path: String?) async -> String

    /// 按 view 坐标（point，单位 pt）反查命中的 DOM 节点。
    func probe(webviewId: String?, x: Double, y: Double) async -> String

    /// 页面源码或资源清单。`kind`: "html" | "resources"。
    func pageSource(webviewId: String?, kind: String, maxBytes: Int) async -> String

    /// 在页面里执行 JS，返回 JSON 可序列化结果的字符串描述。
    func eval(webviewId: String?, script: String, inPageWorld: Bool) async -> String

    /// 开始采集 web 侧 console 与 JS 异常（按需装探针，未开启时页面零改动）。
    func consoleStart(webviewId: String?) async -> String

    /// 读取已采集的 console 记录（按 seq 升序，取尾部 limit 条）。
    func consoleRead(webviewId: String?, limit: Int, sinceSeq: UInt64?) async -> String

    /// 停止采集并摘除探针（已注入页面的代理函数在下次页面加载后自然消失）。
    func consoleStop(webviewId: String?) async -> String
}

public extension WebInspectProvider {

    func probe(webviewId: String?, x: Double, y: Double) async -> String {
        "Inspection denied: probe is not supported by this web provider."
    }

    func pageSource(webviewId: String?, kind: String, maxBytes: Int) async -> String {
        "Inspection denied: page_source is not supported by this web provider."
    }

    func eval(webviewId: String?, script: String, inPageWorld: Bool) async -> String {
        "Inspection denied: eval is not supported by this web provider."
    }

    func consoleStart(webviewId: String?) async -> String {
        "Inspection denied: console capture is not supported by this web provider."
    }

    func consoleRead(webviewId: String?, limit: Int, sinceSeq: UInt64?) async -> String {
        "Inspection denied: console capture is not supported by this web provider."
    }

    func consoleStop(webviewId: String?) async -> String {
        "Inspection denied: console capture is not supported by this web provider."
    }
}
