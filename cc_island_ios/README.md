# Claude Code Island iOS Scaffold

这个目录提供 iOS Companion 的代码骨架，目标是快速接入：

1. Live Activities / Dynamic Island 展示 Claude Code 任务状态
2. 在灵动岛上执行审批动作（Approve / Reject）
3. 从本地 `cc-stats-bridge` 拉取状态并回传审批

## 推荐 Xcode Target 结构

1. `ClaudeCodeIslandApp`（iOS App target）
2. `ClaudeCodeIslandWidgetExtension`（Widget Extension target）

也可直接使用本目录的 `project.yml` 通过 XcodeGen 生成工程。

## 文件放置建议

### App + Widget 都需要

1. `Shared/BridgeModels.swift`
2. `Shared/ClaudeCodeIslandAttributes.swift`
3. `Shared/BridgeConfiguration.swift`
4. `Networking/BridgeClient.swift`

### 仅 App target

1. `App/ClaudeCodeActivityManager.swift`
2. `App/BridgeSyncCoordinator.swift`

### 仅 Widget Extension target

1. `Widgets/ClaudeCodeIslandWidget.swift`
2. `Intents/ApprovalIntents.swift`

## 启动联调（本机）

1. 启动 bridge：

```bash
cc-stats-bridge --host 127.0.0.1 --port 8765
```

2. 手机端桥接地址配置：
   - 默认读取 `UserDefaults(suiteName: "group.ccstats.island")` 的 `bridge_base_url`
   - 模拟器可用 `http://127.0.0.1:8765`
   - 真机调试建议改成开发机局域网 IP（如 `http://192.168.1.10:8765`）

3. 开启 hooks -> bridge（可选）：

```bash
export CC_STATS_BRIDGE_URL="http://127.0.0.1:8765"
cc-stats --install-hooks
```

## XcodeGen 一键生成工程（推荐）

```bash
brew install xcodegen
cd cc_island_ios
xcodegen generate
open ClaudeCodeIsland.xcodeproj
```

## 无真实会话时的联调

```bash
cd ..
./scripts/island_dev_boot.sh
```
