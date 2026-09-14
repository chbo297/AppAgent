//
//  AppAgentTextField.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// `UITextField` that uses the full horizontal width of its `bounds` for text,
/// placeholder, and caret (no system default left/right text insets).
///
/// - Note: If you enable `clearButtonMode` other than `.never`, you may need to
///   inset the right edge of `textRect` / `editingRect` to avoid overlap with the clear button.
public final class AppAgentTextField: UITextField {

    public override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds
    }

    public override func editingRect(forBounds bounds: CGRect) -> CGRect {
        bounds
    }

    public override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        bounds
    }
}

#endif
