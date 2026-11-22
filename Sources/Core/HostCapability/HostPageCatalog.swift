//
//  HostPageCatalog.swift
//  AppAgent — 宿主能力层
//
//  页面的产品说明由宿主提供：app_ui 用它说「当前是首页」，而不是「当前是 BMMapMainPage」；
//  app_runtime_inspect 在类名后面附上同一份说明。宿主没登记的页面，app_ui 才退回系统标题或类名。
//

#if canImport(UIKit)
import UIKit

/// 一个页面在产品上的名字和用途。
public struct HostPageDescription: Sendable, Equatable {
    /// 页面名，如「地图首页」。
    public let name: String
    /// 一句话用途，可省略。
    public let purpose: String?

    public init(name: String, purpose: String? = nil) {
        self.name = name
        self.purpose = purpose
    }
}

/// 宿主登记页面说明的入口。宿主在启动时设置一次 `describer`；返回 nil 表示这个控制器没有登记。
@MainActor
public enum HostPageCatalog {
    public static var describer: (@MainActor (UIViewController) -> HostPageDescription?)?

    static func description(of controller: UIViewController) -> HostPageDescription? {
        guard let describer, let description = describer(controller),
              !description.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return description
    }
}

/// 运行时内省输出里页面和视图的称呼，按 `HostInspectionContext.presentation` 区分。
@MainActor
enum HostUINaming {

    /// 页面称呼。product：登记名 → 系统标题 → 「未登记页面 类名」；implementation：类名 + 登记说明。
    static func page(_ controller: UIViewController, context: HostInspectionContext) -> String {
        let className = String(describing: type(of: controller))
        let description = HostPageCatalog.description(of: controller)
        switch context.presentation {
        case .implementation:
            guard let description else {
                return className
            }
            return "\(className)（\(text(of: description))）"
        case .product:
            if let description {
                return "「\(text(of: description))」"
            }
            if controller is UINavigationController {
                return "导航栈"
            }
            if controller is UITabBarController {
                return "Tab 容器"
            }
            if let title = title(of: controller) {
                return "「\(title)」页"
            }
            return "未登记页面 \(className)"
        }
    }

    /// 视图称呼。product 用控件类别（按钮、文本、列表…），文字另由调用方附上；
    /// 没有任何文字的宿主自定义视图才带类名。implementation 用类名。
    static func view(_ view: UIView, context: HostInspectionContext) -> String {
        let className = String(describing: type(of: view))
        guard context.presentation == .product else {
            return className
        }
        let role = role(of: view, className: className)
        let isSystemClass = className.hasPrefix("UI") || className.hasPrefix("_UI") || className.hasPrefix("WK")
        if hasVisibleText(view) || isSystemClass {
            return role
        }
        return "\(role)（\(className)）"
    }

    /// 视图所在的页面：沿响应链找到最近的控制器。
    static func owningPage(of view: UIView, context: HostInspectionContext) -> String? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController {
                return page(controller, context: context)
            }
            responder = current.next
        }
        return nil
    }

    static func hasVisibleText(_ view: UIView) -> Bool {
        if let label = view as? UILabel, label.text?.isEmpty == false {
            return true
        }
        if let button = view as? UIButton, button.title(for: .normal)?.isEmpty == false {
            return true
        }
        if let field = view as? UITextField, field.text?.isEmpty == false || field.placeholder?.isEmpty == false {
            return true
        }
        return view.accessibilityLabel?.isEmpty == false
    }

    static func role(of view: UIView, className: String) -> String {
        switch view {
        case is UIWindow:
            return "窗口"
        case is UIButton:
            return "按钮"
        case is UISwitch:
            return "开关"
        case is UITextField, is UISearchBar:
            return "输入框"
        case is UISegmentedControl:
            return "分段选择"
        case is UISlider:
            return "滑块"
        case is UIControl:
            return "控件"
        case is UILabel:
            return "文本"
        case is UITextView:
            return "文本区"
        case is UIImageView:
            return "图片"
        case is UITableView, is UICollectionView:
            return "列表"
        case is UIScrollView:
            return className.hasPrefix("WK") ? "网页" : "滚动区"
        case is UITabBar:
            return "底部 Tab 栏"
        case is UINavigationBar:
            return "导航栏"
        default:
            return className.hasPrefix("WK") ? "网页" : "视图"
        }
    }

    private static func text(of description: HostPageDescription) -> String {
        guard let purpose = description.purpose, !purpose.isEmpty else {
            return description.name
        }
        return "\(description.name)：\(purpose)"
    }

    private static func title(of controller: UIViewController) -> String? {
        let candidates = [controller.title, controller.navigationItem.title, controller.tabBarItem?.title]
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return DefaultRuntimeInspectProvider.clip(candidate)
            }
        }
        return nil
    }
}
#endif
