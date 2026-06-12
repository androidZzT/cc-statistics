<div align="center">
  <img src="docs/desktop_now.png" width="480" alt="cc-statistics macOS App" style="border-radius: 16px;">
  <h1>cc-statistics</h1>
  <p><strong>Claude Code、Gemini CLI、Codex CLI、Cursor を1つのネイティブ macOS アプリに統合した、唯一の AI コーディングトラッカーです。</strong></p>
  <p><em>すべての AI ツールの token、コスト、session を追跡。100% ローカル。ゼロ依存。</em></p>

  <p>
    <a href="https://pypi.org/project/cc-statistics/"><img src="https://img.shields.io/pypi/v/cc-statistics?color=blue&style=flat-square&logo=python" alt="PyPI"></a>
    <a href="https://pepy.tech/project/cc-statistics"><img src="https://static.pepy.tech/badge/cc-statistics/month" alt="Downloads"></a>
    <a href="https://github.com/androidZzT/cc-statistics/stargazers"><img src="https://img.shields.io/github/stars/androidZzT/cc-statistics?style=flat-square" alt="Stars"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/androidZzT/cc-statistics?style=flat-square" alt="License"></a>
    <img src="https://img.shields.io/badge/zero--dependencies-stdlib%20only-orange?style=flat-square" alt="Zero Dependencies">
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey?style=flat-square" alt="Platform">
  </p>

  <p>
    <a href="#-なぜ-cc-statistics-なのか">なぜ？</a> &bull;
    <a href="#-機能">機能</a> &bull;
    <a href="#%EF%B8%8F-スクリーンショット">スクショ</a> &bull;
    <a href="#-クイックスタート">クイックスタート</a> &bull;
    <a href="#-cli-リファレンス">CLI</a> &bull;
    <a href="README.md">English</a> | <a href="README_CN.md">简体中文</a> | 日本語 | <a href="README_KO.md">한국어</a>
  </p>
</div>

---

## 🤔 なぜ cc-statistics なのか？

複数の AI コーディングツールを使っていても、実際には把握できていないことがあります：

- 💸 **Claude Code、Gemini CLI、Codex、Cursor を合わせた総コスト**は？
- 🔧 **最も頻繁に呼ばれている MCP ツール**は何で、その token コストは見合っているか？
- ⏱️ **Claude が実際に処理している時間**と、あなたを待っている時間の比率は？
- 📈 **最もリソースを消費しているプロジェクト**はどれで、どのモデルを使っているか？

ほとんどのツールは Claude Code だけに答えます。cc-statistics は4つすべてに答えます。

### 比較表

| | cc-statistics | CCDash | claude-usage | ccflare |
|---|:---:|:---:|:---:|:---:|
| **Claude Code** | ✅ | ✅ | ✅ | ✅ |
| **Gemini CLI** | ✅ | ❌ | ❌ | ❌ |
| **Codex CLI** | ✅ | ❌ | ❌ | ❌ |
| **Cursor** | ✅ | ❌ | ❌ | ❌ |
| **ネイティブ macOS アプリ** | ✅ | ❌ | ❌ | ❌ |
| **ピクセルアートマスコット (Clawd)** | ✅ | ❌ | ❌ | ❌ |
| **session 検索・再開** | ✅ | ✅ | ❌ | ❌ |
| **週次 / 月次レポート** | ✅ | ✅ | ❌ | ❌ |
| **Webhook** (Slack / Feishu / DingTalk) | ✅ | ✅ Slack/Discord | ❌ | ❌ |
| **ツール呼び出し分析** | ✅ | ✅ | ❌ | ❌ |
| **言語別コード変更量** | ✅ | ❌ | ❌ | ❌ |
| **AI vs ユーザー処理時間** | ✅ | ❌ | ❌ | ❌ |
| **使用量アラート** | ✅ | ✅ | ❌ | ❌ |
| **使用量クォータ予測** | ✅ | ✅ | ❌ | ❌ |
| **session メッセージ共有** | ✅ | ❌ | ❌ | ❌ |
| **Web ダッシュボード** | ✅ | ✅ | ✅ | ✅ |
| **CLI ツール** | ✅ | ✅ | ❌ | ✅ |
| **ゼロ依存** | ✅ | ✅ | ❌ | ❌ |
| cache 効率グレード | ⏳ 予定 | ✅ | ❌ | ❌ |
| ライブストリーム | ⏳ 予定 | ✅ | ❌ | ❌ |

> cc-statistics はコミュニティプロジェクトであり、Anthropic、Google、OpenAI とは無関係です。

---

## 🚀 機能

### 🌐 4プラットフォーム統合ビュー
> Claude Code · Gemini CLI · Codex CLI · Cursor — プラットフォームを切り替えるか、4つすべてを1つのレポートに集約できます。各データソースはローカルファイルから読み取ります。API key 不要、アカウント不要、ネットワーク通信なし。

### 🖥️ ネイティブ macOS メニューバーアプリ
> ビルド済み SwiftUI バイナリ — `cc-stats-app` を実行するとメニューバーに常駐します。Claude ロゴ + 本日の token 数 + 推定コストをひと目で確認できます。日次使用量クォータに達すると**赤く**なります。右クリックで表示モードを切り替え。グローバルホットキー `Cmd+Shift+C` でどこからでもフルダッシュボードを開けます。

### 🏝️ Claude スタイル Island オーバーレイ
> ノッチ対応の Island オーバーレイで、コンパクト状態と展開状態で Claude Code のアクティビティや権限リクエストを表示します。常にターミナルに戻ることなく、承認の確認や chat コンテキストへの移動ができます。

### 🐾 Clawd — ピクセルアートステータスバーマスコット
> ピクセルアートの Clawd マスコットが Claude Code の agent 状態にリアルタイムで反応します：アイドル、思考中、タイピング、ハッピー、スリープ、エラー — それぞれ独自のアニメーションスプライトつき。[clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) の hook 統合で実現。

<img src="docs/clawd-states.png" width="600" alt="Clawd Animation States">

### 📊 使用量クォータ予測
> 現在の消費率に基づいて、いつ使用量クォータに達するかをリアルタイムで予測します。残り時間の見積もり、リセット予定時刻、リスクレベルを表示し、意図しない制限を避けられます。

### 🔍 session 検索・再開
> すべてのプラットフォームのsession履歴をキーワードで横断検索できます。結果にはタイムスタンプとすぐに実行できる再開コマンドが表示されます — コピーペーストで即座にコンテキストに戻れます：
> ```bash
> claude --resume <session-id>
> ```

### 💬 session メッセージ共有
> 個々のsession会話をきれいにフォーマットされたテキストとしてエクスポート・共有できます。AI支援作業の記録、チームメンバーとのコンテキスト共有、重要なsessionのアーカイブに便利です。

### 📊 多次元分析
> 指示回数 · ツール呼び出し Top 10（Skill と MCP ツールを名称別に分類）· AI 処理時間 vs ユーザーアクティブ時間 · 言語別コード変更量（`git log --numstat` 経由）· モデル別 token 内訳 · Opus / Sonnet / Haiku / Gemini 2.5 Pro / Flash / GPT-4o の内蔵価格によるコスト推算

### 🔔 使用量アラート
> 日次・週次のコスト上限を設定できます。閾値を超えると macOS メニューバーアイコンが赤くなり、ネイティブシステム通知が発火します — フォーカスモードに対応し、アプリをフォアグラウンドにする必要はありません。

### 📋 週次・月次レポート
> 任意の期間の Markdown サマリーを自動生成：総 token 数、モデル別コスト、最もアクティブなプロジェクト、上位ツール呼び出し、言語別コード変更。チームチャンネルに直接プッシュ：
> ```bash
> cc-stats --report week
> cc-stats --notify https://hooks.slack.com/services/xxx
> ```
> Slack、Feishu、DingTalk の webhook に対応。

### ⚡ プロジェクト比較
> プロジェクトごとのリソース消費量を並べて確認：
> ```bash
> cc-stats --compare --since 1w
> ```

### 🌐 Web ダッシュボード
> すべてのプラットフォーム対応のブラウザベース・ダークテーマダッシュボード — Linux/Windows や、メニューバーパネルより大きなビューが必要なときに便利です。

### 🔒 100% ローカル & ゼロ依存
> すべてのデータはローカルファイルから読み取ります。ネットワーク経由で送信されるものは何もありません。Pure Python 標準ライブラリ — `pip install` 不要、npm 不要、Docker 不要。

---

## 🖼️ スクリーンショット

<table>
  <tr>
    <td align="center"><strong>🖥️ macOS アプリ — ダークモード</strong></td>
    <td align="center"><strong>🖥️ macOS アプリ — ライトモード</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-dark.png" alt="macOS App Dark" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-light.png" alt="macOS App Light" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>📊 使用量クォータ予測</strong></td>
    <td align="center"><strong>🔴 最大使用量到達</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-predict.png" alt="Usage Quota Predictor" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-max-usage.png" alt="Max Usage" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🔍 session 一覧</strong></td>
    <td align="center"><strong>🔧 ツール呼び出し分析</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-sessions.png" alt="Session List" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-tools.png" alt="Tool Call Analytics" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>⚡ Skill / MCP 分析</strong></td>
    <td align="center"><strong>💬 session メッセージ共有</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-skill.png" alt="Skill Analytics" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-share-msgs.png" alt="Share Messages" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🌐 4プラットフォーム統合ビュー</strong></td>
    <td align="center"><strong>⚙️ 設定</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-multiplatform.png" alt="Multi-Platform" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-settings.png" alt="Settings" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🔔 通知</strong></td>
    <td align="center"><strong>🌐 Web ダッシュボード</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-notification.png" alt="Notifications" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-web.png" alt="Web Dashboard" width="100%"></td>
  </tr>
</table>

### CLI デモ

<img src="docs/screenshots/cc-stat-cli.png" width="680" alt="CC Stats CLI Demo">

---

## ⚡ クイックスタート

### 前提条件

- Python 3.8+
- Claude Code CLI、Gemini CLI、Codex CLI、Cursor のいずれか1つ以上がインストール・使用済みであること

### 3ステップ

```bash
# 1. インストール
uv tool install cc-statistics   # または: pipx install cc-statistics

# 2. 最初のレポートを実行（全プラットフォーム、直近7日間）
cc-stats --all --since 7d

# 3. macOS メニューバーアプリを起動（macOS のみ）
cc-stats-app
```

設定ファイルは不要です。

**その他のインストール方法：**

```bash
# pipx
pipx install cc-statistics

# Homebrew (macOS / Linux)
brew install androidZzT/tap/cc-statistics
```

---

## 📖 CLI リファレンス

```bash
cc-stats                      # カレントディレクトリの session を分析
cc-stats --list               # 検出されたすべてのプロジェクトを一覧表示（全プラットフォーム）
cc-stats --all --since 3d     # 直近3日間、全プロジェクト、全プラットフォーム
cc-stats --all --since 1w     # 直近1週間
cc-stats myproject --last 3   # 特定プロジェクトの直近3 session
cc-stats --report week        # 週次 Markdown レポートを生成
cc-stats --report month       # 月次 Markdown レポートを生成
cc-stats --compare --since 1w # プロジェクト並列比較
cc-stats --notify <url>       # Slack / Feishu / DingTalk webhook にレポートをプッシュ
cc-stats-web                  # ブラウザで Web ダッシュボードを開く
cc-stats-app                  # macOS メニューバーアプリを起動
```

---

## 🗂️ データソース

すべてのデータはローカルファイルから読み取ります。ネットワーク経由で送信されるものは何もありません。

| ソース | ローカルパス |
|--------|-----------|
| Claude Code | `~/.claude/projects/<project>/<session>.jsonl` |
| Gemini CLI | `~/.gemini/tmp/<project>/chats/<session>.json` |
| Codex CLI | `~/.codex/sessions/*.jsonl` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Git 変更 | プロジェクトディレクトリでの `git log --numstat` |

---

## 謝辞

ステータスバーの Clawd アニメーションスプライトは [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) より — AI コーディング agent の状態を hook で感知してピクセルアートアニメーションを再生する Electron デスクトップペットアプリです。

[Farouq Aldori](https://github.com/farouqaldori) と [claude-island / vibe-notch](https://github.com/farouqaldori/vibe-notch) プロジェクトに特別な感謝を。macOS ノッチ island のインタラクションモデル、コンパクト/展開のモーション言語、承認パネルのデザイン方向性においてインスピレーションをいただきました。

---

## サポート

cc-statistics が AI コーディングのコスト削減に役立っているなら、プロジェクトへの[スポンサー](https://github.com/sponsors/androidZzT)をご検討ください。
