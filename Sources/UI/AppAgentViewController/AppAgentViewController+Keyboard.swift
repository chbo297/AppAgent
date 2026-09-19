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
        observer.onChange = { [weak self] height, duration in
            self?.handleKeyboardHeightChange(height: height, duration: duration)
        }
        keyboardObserver = observer
    }

    func handleKeyboardHeightChange(height: CGFloat, duration: TimeInterval) {
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

        UIView.animate(withDuration: duration) {
            self.layoutInputBar(reason: .keyboard)
        }

        scrollToBottom(animated: true)
    }
}

#endif
