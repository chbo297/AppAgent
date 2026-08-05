//
//  OpenAPPViewController+Keyboard.swift
//  OpenAPPUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Keyboard

extension OpenAPPViewController {
    func setupKeyboardObservers() {
        let observer = OpenAPPKeyboardObserver(referenceView: view)
        observer.onChange = { [weak self] height, duration in
            self?.handleKeyboardHeightChange(height: height, duration: duration)
        }
        keyboardObserver = observer
    }

    func handleKeyboardHeightChange(height: CGFloat, duration: TimeInterval) {
        let oldEffectiveKeyboardHeight = effectiveKeyboardHeight
        observedKeyboardHeight = height
        let newEffectiveKeyboardHeight = effectiveKeyboardHeight

        // 列表只补偿整体位移后剩余的底部遮挡；inputBar 与 ChatPanel 容器在下方同一动画中同步上移。
        UIView.animate(withDuration: max(duration, 0.01)) {
            self.updateChatPanelListInsets()
        }

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
