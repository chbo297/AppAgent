//
//  RuntimeInspectProvider.swift
//  OpenAPP — Liji 集成层
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
    /// 反射调用：className 上的 selector，参数以 JSON 数组字符串传入，返回结果描述。
    func invoke(className: String, selector: String, argumentsJSON: String) async -> String
}
