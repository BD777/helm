# UI Design Notes — Helm

## 设计原则

1. **薄 GUI**：不重写 agent，不重写 session。Helm 是渲染层 + 编排层。
2. **Codex App 美学**：克制、扁平、macOS native。窗口可裁性强，键盘优先。
3. **尊重 vendor 配置**：本机/远端的 `~/.codex` `~/.claude` 是事实之源。Helm 只在自己的 DB 里存索引。
4. **延迟抽象**：adapter 内部统一事件流，但保留 raw vendor event。

## 已锁决策

| 项 | 决策 |
|---|---|
| 工程名 | **Helm**（locked） |
| 窗口数 | 单窗口，左侧栏切换 |
| 消息历史 | lazy 从 vendor session 拉，LRU 显存缓存 |
| 远端 runner 传输 | 抄 Codex App：`ssh exec` spawn 远端 runner，JSON-RPC over SSH-tunneled stdio。SSH 本身就是 keepalive/重连。 |
| MVP 范围 | 见下方 |

## MVP 范围（v1 必做）

- 本地 + SSH 两种 Project
- Claude + Codex 两个 adapter（封装 vendor SDK 调用）
- Session 新建 / resume / 切换 / 重命名 / 归档
- Streaming 消息流（含 tool / diff / approval 渲染）
- Per-session 模型切换
- Per-session 同生态 Profile 切换（**做**，见下）
- Vendor 设置（Claude: thinking；Codex: reasoning effort）
- 命令面板 / 键盘快捷键
- Markdown + 代码高亮渲染

## MVP 外（v2+）

- skills 管理 UI（先靠 symlink 手工，后期做 UI）
- 跨生态 session 同步（Claude ↔ Codex 不会做，语义不通）
- plugin / MCP 安装器
- computer use
- 内置 diff 编辑器（先用外部）
- 多窗口
- 团队协作 / 云同步

## 信息架构

```
Window (NavigationSplitView，单窗口)
├── Sidebar (~280pt)
│   ├── Toolbar: [+ New] [⚙ Profiles] [↻]
│   ├── Search field
│   └── Project tree (sectioned)
│       ├── 📁 helm   local   ~/workspace/helm
│       │   ├── Session "Wire up ACP adapter"     CC  •  2m
│       │   ├── Session "Sketch session schema"   Cx  •  34m
│       │   └── + New chat in helm
│       ├── 📁 ccm    local   ~/workspace/ccm
│       └── ● staging-api  ssh build-host  /srv/api    (●=conn-state)
│
└── Detail (chat pane)
    ├── Toolbar
    ├── Message list (virtualized scroll, LRU cached)
    └── Composer
```

**Local project icon**：📁 folder 图标，灰色  
**SSH project icon**：状态圆点
  - 🟢 green = connected
  - 🟡 yellow = connecting / reconnecting
  - 🔴 red = failed / disconnected

## 实体定义

```
Profile        host + provider + configRoot + envOverlay + commandPath
                 e.g. {host: localhost, provider: claude,
                       envOverlay: {ANTHROPIC_BASE_URL: team-gateway},
                       commandPath: /usr/local/bin/claude}
Project        host + cwd + title + defaultProfileId
Session        projectId + currentProfileId + vendorSessionId + model
               + vendorSettings + title + lastEventAt
Message        sessionId + role + parts[]
Part           text | tool_call | tool_output | diff | approval | reasoning | image
```

- `vendorSessionId` 来自 Codex/Claude SDK，resume 时回填给 SDK
- `Profile` 默认 = 本机当前 shell 环境 + 默认 codex/claude 二进制
- 多账号 = 多 Profile（不同 env、不同 configRoot 或不同 binary path）
- `vendorSettings` 是 per-vendor JSON：
  - Claude: `{ thinking: bool, thinkingBudget?: int, compactionWindow: int, subagentModel?: str }`
  - Codex: `{ reasoningEffort: "minimal"|"low"|"medium"|"high", sandbox?: str }`

## 同生态 Profile 切换（MVP 做）

**场景**：当前 Claude 会话跑着 team-gateway profile，gateway 挂了，用户想换到 direct anthropic.com 继续这个 session。

**实现**：
1. Sidebar 不动；session 不变；只换 underlying SDK 连接
2. Adapter 收到 switch profile 指令：
   - 优雅停掉当前 SDK 连接（不丢已写入的本地 session 文件）
   - 用新 profile 的 env + binary path 起一个新 SDK 连接，传同一个 `vendorSessionId`
3. UI 显示 "Reconnecting via direct (anthropic.com)..." toast 约 1s

**前提**：两个 profile 必须能读到同一个 session 文件 = 两个 profile 的 `configRoot` 必须一致（否则 SDK 找不到 session）。一般情况下默认就一致（都用 `~/.claude`），不一致时 picker 里禁用这个 profile 项并显示原因。

**跨生态（Claude → Codex）**：MVP 不做。在 picker 里走 "Switch ecosystem" 段，明确 "starts new session"。

## Vendor 设置

picker dropdown 里加一段 "Claude settings" / "Codex settings"，按当前 vendor 显示对应项：

- **Claude**: Extended thinking toggle、Compaction window、Subagent model
- **Codex**: Reasoning effort (minimal/low/medium/high)、Sandbox 模式

切换会写入 session 的 `vendorSettings`，下一条消息生效。

## 三类核心特性的展示规则

### 1. Tool call
折叠卡片，颜色：成功 muted；失败红边；running spinner。

### 2. Diff / file edit
unified diff，+/- 计数，点击文件名 → 本机用默认编辑器打开（SSH 模式下复制远端路径）。

### 3. Approval request
inline 卡片（非 modal），按钮 Deny / Approve once / Always allow X in this project。
"Always" 写入该 Project 的 approval policy。

## 键盘

| Shortcut         | Action                          |
|------------------|---------------------------------|
| ⌘N               | New chat (in current project)   |
| ⌘⇧N              | New project                     |
| ⌘K               | Quick switcher (project+session)|
| ⌘/               | Focus composer                  |
| ⌘↵               | Send                            |
| ⌘.               | Stop / cancel run               |
| ⌘1..9            | Switch to sidebar item N        |
| ⌘⌥←/→            | Prev/next session in project    |
| ⌘[ / ⌘]          | Collapse / expand sidebar       |
| ⌘F               | Find in current session         |

## Streaming UI

- assistant 消息：左侧 caret 闪烁，token 流式追加
- 工具调用：spinner → 完成后状态切换
- 顶部右上角小态：`● Running · 0:12` 显示用时与停止按钮
- 用户在 streaming 中再发 → 自动 cancel 前一次 turn（带 toast 确认 undo）
