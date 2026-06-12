<div align="center">
  <img src="docs/desktop_now.png" width="480" alt="cc-statistics macOS App" style="border-radius: 16px;">
  <h1>cc-statistics</h1>
  <p><strong>Claude Code, Gemini CLI, Codex CLI, Cursor를 하나의 네이티브 macOS 앱으로 통합한 유일한 AI 코딩 트래커입니다.</strong></p>
  <p><em>모든 AI 도구의 token, 비용, session을 추적합니다. 100% 로컬. 제로 의존성.</em></p>

  <p>
    <a href="https://pypi.org/project/cc-statistics/"><img src="https://img.shields.io/pypi/v/cc-statistics?color=blue&style=flat-square&logo=python" alt="PyPI"></a>
    <a href="https://pepy.tech/project/cc-statistics"><img src="https://static.pepy.tech/badge/cc-statistics/month" alt="Downloads"></a>
    <a href="https://github.com/androidZzT/cc-statistics/stargazers"><img src="https://img.shields.io/github/stars/androidZzT/cc-statistics?style=flat-square" alt="Stars"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/androidZzT/cc-statistics?style=flat-square" alt="License"></a>
    <img src="https://img.shields.io/badge/zero--dependencies-stdlib%20only-orange?style=flat-square" alt="Zero Dependencies">
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey?style=flat-square" alt="Platform">
  </p>

  <p>
    <a href="#-왜-cc-statistics인가">왜?</a> &bull;
    <a href="#-기능">기능</a> &bull;
    <a href="#%EF%B8%8F-스크린샷">스크린샷</a> &bull;
    <a href="#-빠른-시작">빠른 시작</a> &bull;
    <a href="#-cli-레퍼런스">CLI</a> &bull;
    <a href="README.md">English</a> | <a href="README_CN.md">简体中文</a> | <a href="README_JA.md">日本語</a> | 한국어
  </p>
</div>

---

## 🤔 왜 cc-statistics인가?

여러 AI 코딩 도구를 사용하고 있지만 실제로 알고 있나요:

- 💸 **Claude Code, Gemini CLI, Codex, Cursor를 합산한 총 비용**은 얼마인가요?
- 🔧 **가장 많이 호출되는 MCP 도구**는 무엇이고, 그 token 비용이 합리적인가요?
- ⏱️ **Claude가 실제로 처리하는 시간**과 당신을 기다리는 시간의 비율은?
- 📈 **가장 많은 리소스를 소비하는 프로젝트**는 어떤 모델을 사용하고 있나요?

대부분의 도구는 Claude Code에 대해서만 답해줍니다. cc-statistics는 네 가지 플랫폼 모두에 답합니다.

### 비교표

| | cc-statistics | CCDash | claude-usage | ccflare |
|---|:---:|:---:|:---:|:---:|
| **Claude Code** | ✅ | ✅ | ✅ | ✅ |
| **Gemini CLI** | ✅ | ❌ | ❌ | ❌ |
| **Codex CLI** | ✅ | ❌ | ❌ | ❌ |
| **Cursor** | ✅ | ❌ | ❌ | ❌ |
| **네이티브 macOS 앱** | ✅ | ❌ | ❌ | ❌ |
| **픽셀 아트 마스코트 (Clawd)** | ✅ | ❌ | ❌ | ❌ |
| **session 검색 및 재개** | ✅ | ✅ | ❌ | ❌ |
| **주간 / 월간 리포트** | ✅ | ✅ | ❌ | ❌ |
| **Webhook** (Slack / Feishu / DingTalk) | ✅ | ✅ Slack/Discord | ❌ | ❌ |
| **툴 호출 분석** | ✅ | ✅ | ❌ | ❌ |
| **언어별 코드 변경량** | ✅ | ❌ | ❌ | ❌ |
| **AI vs 사용자 처리 시간** | ✅ | ❌ | ❌ | ❌ |
| **사용량 알림** | ✅ | ✅ | ❌ | ❌ |
| **사용량 쿼터 예측** | ✅ | ✅ | ❌ | ❌ |
| **session 메시지 공유** | ✅ | ❌ | ❌ | ❌ |
| **Web 대시보드** | ✅ | ✅ | ✅ | ✅ |
| **CLI 도구** | ✅ | ✅ | ❌ | ✅ |
| **제로 의존성** | ✅ | ✅ | ❌ | ❌ |
| cache 효율 등급 | ⏳ 예정 | ✅ | ❌ | ❌ |
| 라이브 스트림 | ⏳ 예정 | ✅ | ❌ | ❌ |

> cc-statistics는 커뮤니티 프로젝트로, Anthropic, Google, OpenAI와는 무관합니다.

---

## 🚀 기능

### 🌐 4-플랫폼 통합 뷰
> Claude Code · Gemini CLI · Codex CLI · Cursor — 플랫폼 간 전환하거나 네 가지 모두를 하나의 리포트로 통합할 수 있어요. 각 소스는 로컬 파일에서만 읽어옵니다. API key 불필요, 계정 불필요, 네트워크 통신 없음.

### 🖥️ 네이티브 macOS 메뉴바 앱
> 빌드된 SwiftUI 바이너리 — `cc-stats-app`을 실행하면 메뉴바에 상주합니다. Claude 로고 + 오늘의 token 수 + 예상 비용을 한눈에 확인할 수 있어요. 일일 사용량 쿼터에 도달하면 **빨간색**으로 변합니다. 우클릭으로 표시 모드를 변경하고, 전역 단축키 `Cmd+Shift+C`로 어디서든 전체 대시보드를 열 수 있어요.

### 🏝️ Claude 스타일 Island 오버레이
> macOS 노치 인식 island 오버레이로 컴팩트 상태와 확장 상태에서 Claude Code의 활동과 권한 요청을 표시합니다. 터미널로 계속 전환하지 않고도 승인 확인, chat 컨텍스트 이동, 흐름 유지가 가능해요.

### 🐾 Clawd — 픽셀 아트 상태바 마스코트
> 픽셀 아트 Clawd 마스코트가 Claude Code의 agent 상태에 실시간으로 반응합니다: 대기, 생각 중, 타이핑, 행복, 수면, 오류 — 각각 고유한 애니메이션 스프라이트가 있어요. [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) hook 통합으로 구현됩니다.

<img src="docs/clawd-states.png" width="600" alt="Clawd Animation States">

### 📊 사용량 쿼터 예측
> 현재 소비율을 기반으로 언제 사용량 쿼터에 도달할지 실시간으로 예측합니다. 남은 예상 시간, 예상 리셋 시간, 위험 수준을 표시해 사용량을 조절하고 예상치 못한 제한을 피할 수 있어요.

### 🔍 session 검색 및 재개
> 모든 플랫폼의 전체 session 히스토리를 키워드로 검색할 수 있어요. 결과에는 타임스탬프와 바로 실행 가능한 재개 명령이 표시됩니다 — 복사-붙여넣기 하나로 컨텍스트로 돌아갈 수 있어요:
> ```bash
> claude --resume <session-id>
> ```

### 💬 session 메시지 공유
> 개별 session 대화를 깔끔하게 포맷된 텍스트로 내보내고 공유할 수 있어요. AI 지원 작업 문서화, 팀원과의 컨텍스트 공유, 중요한 session 아카이브에 유용합니다.

### 📊 다차원 분석
> 명령 횟수 · 툴 호출 Top 10 (Skill과 MCP 툴을 이름별로 분류) · AI 처리 시간 vs 사용자 활성 시간 · 언어별 코드 변경량 (`git log --numstat` 활용) · 모델별 token 분석 · Opus / Sonnet / Haiku / Gemini 2.5 Pro / Flash / GPT-4o 내장 가격 기반 비용 추정

### 🔔 사용량 알림
> 일일 및 주간 비용 한도를 설정할 수 있어요. 임계값을 초과하면 macOS 메뉴바 아이콘이 빨간색으로 바뀌고 네이티브 시스템 알림이 발생합니다 — Focus 모드를 존중하며, 앱이 포그라운드에 있을 필요가 없어요.

### 📋 주간 및 월간 리포트
> 임의의 기간에 대한 Markdown 요약을 자동 생성합니다: 총 token 수, 모델별 비용, 가장 활발한 프로젝트, 상위 툴 호출, 언어별 코드 변경. 팀 채널로 직접 전송:
> ```bash
> cc-stats --report week
> cc-stats --notify https://hooks.slack.com/services/xxx
> ```
> Slack, Feishu, DingTalk webhook 모두 지원합니다.

### ⚡ 프로젝트 비교
> 프로젝트별 리소스 소비량을 나란히 확인하세요:
> ```bash
> cc-stats --compare --since 1w
> ```

### 🌐 Web 대시보드
> 모든 플랫폼을 위한 브라우저 기반 다크 테마 대시보드 — Linux/Windows에서 또는 메뉴바 패널보다 더 큰 화면이 필요할 때 유용합니다.

### 🔒 100% 로컬 & 제로 의존성
> 모든 데이터는 로컬 파일에서 읽어옵니다. 네트워크를 통해 전송되는 것은 없어요. 순수 Python 표준 라이브러리 — `pip install` 불필요, npm 불필요, Docker 불필요.

---

## 🖼️ 스크린샷

<table>
  <tr>
    <td align="center"><strong>🖥️ macOS 앱 — 다크 모드</strong></td>
    <td align="center"><strong>🖥️ macOS 앱 — 라이트 모드</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-dark.png" alt="macOS App Dark" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-light.png" alt="macOS App Light" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>📊 사용량 쿼터 예측</strong></td>
    <td align="center"><strong>🔴 최대 사용량 도달</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-predict.png" alt="Usage Quota Predictor" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-max-usage.png" alt="Max Usage" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🔍 session 목록</strong></td>
    <td align="center"><strong>🔧 툴 호출 분석</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-sessions.png" alt="Session List" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-tools.png" alt="Tool Call Analytics" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>⚡ Skill / MCP 분석</strong></td>
    <td align="center"><strong>💬 session 메시지 공유</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-skill.png" alt="Skill Analytics" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-share-msgs.png" alt="Share Messages" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🌐 4-플랫폼 통합 뷰</strong></td>
    <td align="center"><strong>⚙️ 설정</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-multiplatform.png" alt="Multi-Platform" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-settings.png" alt="Settings" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🔔 알림</strong></td>
    <td align="center"><strong>🌐 Web 대시보드</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-notification.png" alt="Notifications" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-web.png" alt="Web Dashboard" width="100%"></td>
  </tr>
</table>

### CLI 데모

<img src="docs/screenshots/cc-stat-cli.png" width="680" alt="CC Stats CLI Demo">

---

## ⚡ 빠른 시작

### 사전 요구사항

- Python 3.8+
- Claude Code CLI, Gemini CLI, Codex CLI, Cursor 중 하나 이상이 설치되어 사용된 상태

### 3단계

```bash
# 1. 설치
uv tool install cc-statistics   # 또는: pipx install cc-statistics

# 2. 첫 번째 리포트 실행 (모든 플랫폼, 지난 7일)
cc-stats --all --since 7d

# 3. macOS 메뉴바 앱 실행 (macOS 전용)
cc-stats-app
```

설정 파일이 필요 없어요.

**다른 설치 방법:**

```bash
# pipx
pipx install cc-statistics

# Homebrew (macOS / Linux)
brew install androidZzT/tap/cc-statistics
```

---

## 📖 CLI 레퍼런스

```bash
cc-stats                      # 현재 디렉토리 session 분석
cc-stats --list               # 감지된 모든 프로젝트 목록 표시 (모든 플랫폼)
cc-stats --all --since 3d     # 지난 3일, 모든 프로젝트, 모든 플랫폼
cc-stats --all --since 1w     # 지난 1주일
cc-stats myproject --last 3   # 특정 프로젝트의 최근 3개 session
cc-stats --report week        # 주간 Markdown 리포트 생성
cc-stats --report month       # 월간 Markdown 리포트 생성
cc-stats --compare --since 1w # 프로젝트 나란히 비교
cc-stats --notify <url>       # Slack / Feishu / DingTalk webhook으로 리포트 전송
cc-stats-web                  # 브라우저에서 Web 대시보드 열기
cc-stats-app                  # macOS 메뉴바 앱 실행
```

---

## 🗂️ 데이터 소스

모든 데이터는 로컬 파일에서 읽어옵니다. 네트워크를 통해 전송되는 것은 없어요.

| 소스 | 로컬 경로 |
|--------|-----------|
| Claude Code | `~/.claude/projects/<project>/<session>.jsonl` |
| Gemini CLI | `~/.gemini/tmp/<project>/chats/<session>.json` |
| Codex CLI | `~/.codex/sessions/*.jsonl` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Git 변경 | 프로젝트 디렉토리의 `git log --numstat` |

---

## 감사의 말

상태바 Clawd 애니메이션 스프라이트는 [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk)에서 가져왔습니다 — hook을 통해 AI 코딩 agent 상태를 감지하고 픽셀 아트 애니메이션을 재생하는 Electron 데스크탑 펫 앱입니다.

[Farouq Aldori](https://github.com/farouqaldori)와 [claude-island / vibe-notch](https://github.com/farouqaldori/vibe-notch) 프로젝트에 특별한 감사를 드립니다. macOS 노치 island 인터랙션 모델, 컴팩트/확장 모션 언어, 승인 패널 디자인 방향에 영감을 주셨습니다.

---

## 지원

cc-statistics가 AI 코딩 비용을 절약하는 데 도움이 된다면, 프로젝트 [후원](https://github.com/sponsors/androidZzT)을 고려해 주세요.
