//
//  AppAgentViewController+Keyboard.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Keyboard

extension AppAgentViewController {
    func setupKeyboardObservers() {
        let observer = AppAgentKeyboardObserver(referenceView: view)
        observer.onChange = { [weak self] height, animation in
            self?.handleKeyboardHeightChange(height: height, animation: animation)
        }
        keyboardObserver = observer
    }

    func handleKeyboardHeightChange(
        height: CGFloat,
        animation: AppAgentKeyboardObserver.Animation
    ) {
        let oldEffectiveKeyboardHeight = effectiveKeyboardHeight
        observedKeyboardHeight = height
        let newEffectiveKeyboardHeight = effectiveKeyboardHeight

        // 列表底部 inset 是固定几何量（展开态 inputBar 白色背景顶部到屏幕底部），键盘只让 inputBar 与
        // ChatPanel 容器整体上移，这里不再改列表 inset。
        //
        // 只有**我们自己的**输入框拉起的键盘才参与避让（`shouldInputBarAvoidKeyboard`）：宿主 app
        // 自己的输入框弹键盘时 `effectiveKeyboardHeight` 为 0，面板与列表都不动。这是有意的——
        // 那时焦点在宿主界面上，overlay 跟着跳反而干扰；列表被键盘盖住的那一段照旧可以滚上来。
        guard abs(oldEffectiveKeyboardHeight - newEffectiveKeyboardHeight) > 0.5 else {
            return
        }

        // 键盘顶起就一件事：在键盘自己的动画块里重算 inputBar 与 ChatPanel 容器的位置，整个容器
        // 一起上移。面板自身高度、展示高度、档位都不变，块内的派生写入直接提交、继承这条动画上下文。
        // 时长**和曲线**都用键盘给的那份，否则两者同时出发却不同速，中途会看出错位。
        //
        // 这条曲线也要带给宿主：块内的 `applyInputBarFrame` 拿到的是 `.immediate`，
        // 只有这里记得住真实时长曲线，宿主要靠它才能跟着同速移动自己的内容。
        ambientKeyboardAnimation = AppAgentPresentationAnimation(
            duration: animation.duration,
            options: animation.options
        )
        defer { ambientKeyboardAnimation = nil }
        animation.run {
            self.layoutInputBar(reason: .keyboard)
        }
    }
}

#endif
