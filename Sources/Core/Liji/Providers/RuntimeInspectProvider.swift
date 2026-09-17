//
//  RuntimeInspectProvider.swift
//  AppAgent — Liji 集成层
//
//  宿主 app（百度地图）实现，向 app agent 暴露「运行时内省」能力：
//  UI 层级、类列表、方法/属性列表、属性取值、方法调用。
//  这些能力默认关闭，需在百度地图配置中显式打开（LijiConfig.runtimeToolsEnabled）。
//

import Foundation

public protocol RuntimeInspectProvider: Sendable {
    /// 当前 keyWindow 的视图/控制器层级文本。
    func uiHierarchy() async -> String
    /// 列出运行时类名，可用前缀/子串过滤（如 "BM"）。
    func classList(matching filter: String?) async -> [String]
    /// 列出某类的实例方法与类方法签名。
    func methodList(ofClass className: String) async -> [String]
    /// 列出某类的属性（含 ivar）。
    func propertyList(ofClass className: String) async -> [String]
    /// 读取当前栈顶页面（或指定对象）某 keyPath 的属性内容的字符串描述。
    func propertyValue(keyPath: String, ofClass className: String?) async -> String?
    /// KVC 写：向当前栈顶页面（或指定对象）的 keyPath 设置新值，返回结果描述。
    func setPropertyValue(keyPath: String, value: String, ofClass className: String?) async -> String
    /// 反射调用：className 上的 selector，参数以 JSON 数组字符串传入，返回结果描述。
    func invoke(className: String, selector: String, argumentsJSON: String) async -> String

    // MARK: 按路径寻址单个视图（"0/2/1"，root 为 keyWindow）

    /// 带可寻址路径的视图树，便于后续按路径读改单个视图。
    func viewTree(maxDepth: Int) async -> String
    /// 某路径视图的详细信息（类名、frame、层级关系、常用属性）。
    func viewInfo(path: String) async -> String
    /// 改某路径视图：frame/bounds/center/alpha/hidden/backgroundColor/text/cornerRadius 走类型化解析，
    /// 其它 key 走 KVC。返回结果描述。
    func setViewValue(path: String, key: String, value: String) async -> String
    /// 对某路径视图反射调用选择器（removeFromSuperview / setNeedsLayout 等结构性修改）。
    func invokeOnView(path: String, selector: String, argumentsJSON: String) async -> String
}

public extension RuntimeInspectProvider {
    /// 默认不支持 KVC 写，需具体 provider 覆盖实现。
    func setPropertyValue(keyPath: String, value: String, ofClass className: String?) async -> String {
        "setPropertyValue is not supported by this runtime provider."
    }

    func viewTree(maxDepth: Int) async -> String {
        await uiHierarchy()
    }

    func viewInfo(path: String) async -> String {
        "viewInfo is not supported by this runtime provider."
    }

    func setViewValue(path: String, key: String, value: String) async -> String {
        "setViewValue is not supported by this runtime provider."
    }

    func invokeOnView(path: String, selector: String, argumentsJSON: String) async -> String {
        "invokeOnView is not supported by this runtime provider."
    }
}
