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
//  宿主若有自己的容器注册表或页面元数据，可实现本协议接管 `targets()`，
//  以补充容器类型、业务标识和宿主归属信息。
//

import Foundation

public protocol WebInspectProvider: Sendable {

    /// 当前 scene / scope 内可发现的 web 容器清单；id 为 WKWebView 实例生命周期内稳定的 UUID。
    func targets(context: HostInspectionContext) async -> String

    /// 语义锚点 DOM 摘要：只列有文本 / 可交互 / 有 id / 面积够大的节点，大子树折叠成 `⊞ N nodes`。
    /// `webviewId` 为 nil 时取默认容器（可见且面积最大的那个）。
    func domSummary(webviewId: String?, path: String?, maxNodes: Int, context: HostInspectionContext) async -> String

    /// 单节点详情：盒模型、computed 子集、scroll/client 尺寸、祖先链与约束宽度的祖先。
    /// 同时传 selector/path 时在 path 指定的根下查询；空 path 明确指向 document.body。
    func domQuery(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext) async -> String

    /// 「为何没展示」的归因：display / visibility / opacity / 零尺寸 / 祖先裁切 / 视口外 / 被遮挡。
    func whyHidden(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext) async -> String

    /// 原生触摸透传红框。只定位 DOM，不执行调用者提供的 JS；导航、离开 scene/scope
    /// 或容器不可见时自动清理。异步结果不得恢复已经取消或被后续选择替换的标注。
    func highlight(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext) async -> String

    /// 清除目标容器的原生标注，重复调用幂等。
    func clearHighlight(webviewId: String?, context: HostInspectionContext) async -> String

    /// 按 view 坐标（point，单位 pt）反查命中的 DOM 节点。
    func probe(webviewId: String?, x: Double, y: Double, context: HostInspectionContext) async -> String

    /// 页面源码或资源清单。`kind`: "html" | "resources"。
    func pageSource(webviewId: String?, kind: String, maxBytes: Int, context: HostInspectionContext) async -> String

    /// 在页面里执行 JS，返回 JSON 可序列化结果的字符串描述。
    func eval(webviewId: String?, script: String, inPageWorld: Bool, context: HostInspectionContext) async -> String

    /// 开始采集 web 侧 console 与 JS 异常（按需装探针，未开启时页面零改动）。
    func consoleStart(webviewId: String?, context: HostInspectionContext) async -> String

    /// 读取已采集的 console 记录（按 seq 升序，取尾部 limit 条）。
    func consoleRead(webviewId: String?, limit: Int, sinceSeq: UInt64?, context: HostInspectionContext) async -> String

    /// 停止采集并摘除探针（已注入页面的代理函数在下次页面加载后自然消失）。
    func consoleStop(webviewId: String?, context: HostInspectionContext) async -> String
}

public extension WebInspectProvider {

    func highlight(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext) async -> String {
        "Inspection denied: highlight is not supported by this web provider."
    }

    func clearHighlight(webviewId: String?, context: HostInspectionContext) async -> String {
        "Inspection denied: clear_highlight is not supported by this web provider."
    }

    func probe(webviewId: String?, x: Double, y: Double, context: HostInspectionContext) async -> String {
        "Inspection denied: probe is not supported by this web provider."
    }

    func pageSource(webviewId: String?, kind: String, maxBytes: Int, context: HostInspectionContext) async -> String {
        "Inspection denied: page_source is not supported by this web provider."
    }

    func eval(webviewId: String?, script: String, inPageWorld: Bool, context: HostInspectionContext) async -> String {
        "Inspection denied: eval is not supported by this web provider."
    }

    func consoleStart(webviewId: String?, context: HostInspectionContext) async -> String {
        "Inspection denied: console capture is not supported by this web provider."
    }

    func consoleRead(webviewId: String?, limit: Int, sinceSeq: UInt64?, context: HostInspectionContext) async -> String {
        "Inspection denied: console capture is not supported by this web provider."
    }

    func consoleStop(webviewId: String?, context: HostInspectionContext) async -> String {
        "Inspection denied: console capture is not supported by this web provider."
    }
}
