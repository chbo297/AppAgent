# 兄弟仓库联合开发与发布（BODragScroll / BOUIKit）+ AppAgent 自身发版

> **什么时候读这份**：需要改 BODragScroll 或 BOUIKit、或准备发版时。

## AppAgent 自己发版

SwiftPM 的「发布」就是**打 tag 并推上去**，没有中心仓库要注册。顺序不能颠倒：

1. 两个兄弟仓的 tag 必须**已经推到各自远端**（`git ls-remote --tags` 确认），否则消费者解析不到；
   `Package.swift` 里不许有本地 path 依赖
2. 最终树跑完 `swift test` + Catalyst 全量 + demo 构建
3. **clean-room 验证**：`git clone --no-local <本仓> /tmp/x && cd /tmp/x && swift build`。
   这一步专门抓「必需文件没提交 / 被 .gitignore 挡了」——工作区能编不代表消费者能编
4. 同步三处版本号：`CHANGELOG.md` 新条目、`AppAgent.podspec` 的 `s.version`、
   `README.md` 与 `docs/GettingStarted.md` 的 `from:` / `pod` 示例
5. `git tag -a <version> -m ...` + `git push --tags`
6. CocoaPods 侧另需 `pod lib lint`（podspec 的 `source_files` 必须含 `ObjCSupport/**/*.{h,m}`，
   漏了会在链接期报找不到符号）

## BODragScroll 联合开发与发布

- AppAgent 仓库位于当前目录；BODragScroll 是同级、独立的 Git 仓库 `../BODragScroll`。涉及面板拖拽或嵌套滚动时，可以直接修改该源码仓并与 AppAgent 联调。
- Demo 工程直接引用 `../BODragScroll`；根 Swift Package 本地联调时运行 `Scripts/Dependencies/use-local-bodragscroll.sh` 进入 editable checkout，结束后可运行 `Scripts/Dependencies/use-released-bodragscroll.sh` 恢复正式依赖。
- 两个仓库的改动、测试、提交和版本发布必须分别管理；不要把 BODragScroll 源码混入 AppAgent 提交。若 AppAgent 依赖尚未发布的 BODragScroll API，先提交并发布/打标 BODragScroll，再更新 AppAgent 的 SwiftPM/CocoaPods 版本声明并发布 AppAgent。
- AppAgent 正式发布必须通过 SwiftPM/CocoaPods 引入 BODragScroll，不能依赖本机兄弟目录；禁止提交 `Packages/` 中的本地符号链接或其他机器相关路径。

## BOUIKit（UIView hit-testing + 几何便利层）

- 依赖 [`chbo297/BOUIKit`](https://github.com/chbo297/BOUIKit)（SwiftPM `from: "0.3.0"`，源码仓在同级 `../BOUIKit`），提供 `bo_hitAreaOutsets`、`bo_skipsSelfInHitTest`、`bo_pointInsideJudge`、`bo_hitTestHook`。同一个包也被 BWTimeGallery 使用。
- **改 BOUIKit 必须先发版再升 AppAgent**：两仓分别提交，BOUIKit 打 tag 推上去之后才改 AppAgent 的 `Package.swift` 与 demo 工程的 `minimumVersion`（跑 `swift package update BOUIKit` 刷 `Package.resolved`）；**提交里不许出现本地 path 依赖**。
- **联调期间可以先用本地源码**：`Scripts/Dependencies/use-local-bouikit.sh` 把根 `Package.swift` 的 BOUIKit 依赖临时换成 `../BOUIKit` 的 path（原版本号记在 `// BOUIKIT-LOCAL released: x.y.z` 注释里），改完发版后 `Scripts/Dependencies/use-released-bouikit.sh` 还原。不要用 `swift package edit`：xcodebuild（Catalyst 测试、demo 工程）不认 SwiftPM 的 `Packages/` editable checkout，只有命令行 `swift build` 认。demo 工程有自己的 remote package 引用，本地联调 demo 需要在 Xcode 里另加一次本地包，同样不提交。
- 它通过 `method_exchangeImplementations` 换掉 `UIView.point(inside:with:)` 与 `hitTest(_:with:)`，首次设置有效配置时惰性安装，作用域是整个进程；集成文档需向宿主 app 说明这一点。
- 在 macOS 上编译为空模块，因此 AppAgent target 无条件依赖即可；`Sources/UI` 里使用时照常放在 `#if canImport(UIKit)` 内。
- **约定：需要调整命中区就用 BOUIKit，不要再手写 `hitTest` / `point(inside:)`**，除非判定本身有复杂逻辑（路径命中、按状态重定向到别的子视图等）。
- 已接入点：`AppAgentWindow` 与 `AppAgentRegionDebugWindow` 的穿透、`AppAgentChatPanelContainerView` 的「命中自己就穿透」用 `bo_skipsSelfInHitTest`；`AppAgentRegionDebugPanelView` 折叠态外扩用 `bo_hitAreaOutsets`。
- 仍保留手写 override 的三处（都属于复杂判定）：`AppAgentInputBar.hitTest` 把 bar 空白处的触点重定向给输入区；`AppAgentVoiceBottomPanelView` / `AppAgentVoiceActionZoneView` 用贝塞尔路径判定命中。
- 输入区命中：`AppAgentInputBar.extendedInputAreaHitRect` 是「点击弹键盘」和「上滑唤键盘」**共用**的同一块矩形（横向为输入区、纵向撑满 bar 白色背景）。改一处即两者同步，`Tests/UI/AppAgentRegionDebugTests.swift` 有用例锁住这一点。
