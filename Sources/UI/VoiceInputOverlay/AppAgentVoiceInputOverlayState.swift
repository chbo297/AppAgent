//
//  AppAgentVoiceInputOverlayState.swift
//  AppAgentUI
//

#if canImport(UIKit)

/// 语音输入识别过程在 UI 上需要呈现的状态，只表达录音/识别是否已经进入工作流。
enum AppAgentVoiceRecognitionVisualState {
    /// 未触发语音输入，或语音输入已经结束、取消、中断。
    case none

    /// 用户已经触发语音输入，但音频会话或识别任务还在准备中。
    case loading

    /// 已经进入录音/识别阶段，可能持续产生识别文本。
    case recording
}

/// 手指当前所在区域对应的“抬起后执行行为”，只表达用户松手时会发生什么。
enum AppAgentVoiceInputReleaseAction {
    /// 松手发送当前语音输入。
    case send

    /// 松手取消当前语音输入。
    case cancel

    /// 松手进入编辑，把实时识别文本转入输入框。
    case edit
}

#endif
