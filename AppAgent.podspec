Pod::Spec.new do |s|
  s.name             = 'AppAgent'
  s.version          = '0.0.1'
  s.summary          = 'An embedded AI agent SDK for iOS and macOS.'
  s.description      = <<-DESC
    AppAgent is a Swift framework that provides a complete agent loop for
    LLM-powered applications. It includes tool registration, multi-session
    management, streaming responses, memory, skills, and an optional UIKit
    overlay UI.
  DESC

  s.homepage         = 'https://github.com/chbo297/AppAgent'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'AppAgent Contributors' => '' }
  s.source           = { :git => 'https://github.com/chbo297/AppAgent.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.swift_version    = '6.0'

  # ObjCSupport 必须一起进来：Sources 里用它做 ObjC 异常兜底，只收 Sources/**/*.swift
  # 会在链接期报找不到符号。SPM 侧对应独立的 AppAgentObjCSupport target。
  s.source_files     = 'Sources/**/*.swift', 'ObjCSupport/**/*.{h,m}'
  s.public_header_files = 'ObjCSupport/include/*.h'

  # 与 Package.swift 保持同一组版本：BODragScroll 只在 iOS/Catalyst 用，BOUIKit 两端都要。
  s.ios.dependency   'BODragScroll', '~> 2.2.1'
  s.dependency       'BOUIKit', '~> 0.3.0'
  s.ios.frameworks   = 'UIKit', 'AVFoundation'
  s.osx.frameworks   = 'AppKit', 'AVFoundation'
end
