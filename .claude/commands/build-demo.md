---
description: Build the iOS demo app via xcodebuild for the iOS Simulator
---

构建 `Examples/iOS/AppAgentDemo.xcodeproj` 的 demo app。

执行步骤：

1. 检查 `Examples/iOS/config.json` 是否存在。如果不存在，提示用户：
   > "缺少 `Examples/iOS/config.json`，参考 `config.json.example` 创建并填入 API key 后再跑 /build-demo"
   然后停止。
2. 在仓库根目录运行：
   ```
   xcodebuild \
     -project Examples/iOS/AppAgentDemo.xcodeproj \
     -scheme AppAgentDemo \
     -sdk iphonesimulator \
     -destination 'generic/platform=iOS Simulator' \
     -configuration Debug \
     build
   ```
3. 输出处理：
   - 失败：用 `grep -E '(error:|warning:)' | head -40` 抽取关键行，按文件分组。
   - `BUILD SUCCEEDED`：一句话回复"demo 构建通过"。
4. 如果出现 code signing 错误，提示用户检查 Xcode 中 AppAgentDemo target 的 Signing & Capabilities（demo 用 Automatic / Personal Team 即可）。
5. 涉及 `Sources/UI/AppAgent*.swift` 的改动时，构建通过后建议用 `/ui-verify` 在模拟器手测。
