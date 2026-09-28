#if canImport(UIKit)
import UIKit
import XCTest

/// 无 App 宿主的 Catalyst XCTest 不派发 sendActions；验证真实注册的 target/action。
/// 不直接调用业务回调，也不替代真机/模拟器的触摸验收。
@MainActor
func invokeRegisteredAction(_ control: UIControl, for event: UIControl.Event = .touchUpInside) throws {
    let target = try XCTUnwrap(control.allTargets.first as? NSObject)
    let action = try XCTUnwrap(control.actions(forTarget: target, forControlEvent: event)?.first)
    _ = target.perform(NSSelectorFromString(action), with: control)
}
#endif
