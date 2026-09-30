# iOS 集成说明（App + Widget Extension）

## 1) 新建 Targets

优先推荐使用现成模板：

```bash
brew install xcodegen
cd cc_island_ios
xcodegen generate
open ClaudeCodeIsland.xcodeproj
```

模板已包含：

1. iOS App target `ClaudeCodeIslandApp`
2. Widget Extension target `ClaudeCodeIslandWidget`

将 `cc_island_ios/` 下文件按以下方式加入 target：

1. App + Widget 共用：`Shared/*`, `Networking/BridgeClient.swift`
2. 仅 App：`App/*`
3. 仅 Widget：`Widgets/*`, `Intents/ApprovalIntents.swift`

## 2) Capabilities 配置

### App target

1. `App Groups`：`group.ccstats.island`
2. `Background Modes`：可选（若做后台同步）
3. `Push Notifications`：可选（后续做 APNs Live Activity）

### Widget Extension target

1. `App Groups`：同上
2. `Supports Live Activities`：开启

## 3) bridge 地址配置

App 首次启动时写入 App Group：

```swift
let group = UserDefaults(suiteName: "group.ccstats.island")
group?.set("http://192.168.1.10:8765", forKey: "bridge_base_url")
```

> 模拟器可用 `127.0.0.1`，真机需使用开发机局域网 IP。

## 4) App 启动示例

在 App 根视图使用：

```swift
WindowGroup {
    IslandDashboardView()
}
```

`IslandDashboardView` 会自动：

1. 启动 bridge 同步（轮询 + SSE）
2. 更新 Live Activity
3. 展示待审批动作，支持 App 内手动 approve/reject

## 5) 灵动岛审批交互

`ApprovalIntents.swift` 提供：

1. `ApproveApprovalIntent`
2. `RejectApprovalIntent`

在 iOS 17+ 可在 Dynamic Island 直接点击按钮调用桥接 API。

## 6) 本机联调清单

1. 启动 bridge：`cc-stats-bridge --host 127.0.0.1 --port 8765`
2. 可选 hooks 转发：
   - `export CC_STATS_BRIDGE_URL="http://127.0.0.1:8765"`
   - `cc-stats --install-hooks`
3. 启动 iOS App，确认：
   - `Current Task` 有数据
   - Live Activity 正常出现
   - 审批按钮可回传并改变任务状态

4. 若没有真实 Claude 任务，可跑：
   - `./scripts/island_dev_boot.sh`
   - 脚本会启动 bridge 并注入一条含审批动作的演示任务
