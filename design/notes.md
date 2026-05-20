# UI Design Notes — Helm

## 设计原则

1. **薄 GUI**：不重写 agent，不重写 session。Helm 是渲染层 + 编排层。
2. **Codex App 美学**：克制、扁平、macOS native。窗口可裁性强，键盘优先。
3. **尊重 vendor 配置**：本机/远端的 `~/.codex` `~/.claude` 是事实之源。Helm 只在自己的 DB 里存索引。
4. **延迟抽象**：adapter 内部统一事件流，但保留 raw vendor event。

## 信息架构

```
Window (NavigationSplitView)
├── Sidebar (~280pt)
│   ├── Toolbar: [+ New] [⚙ Profiles] [↻]
│   ├── Search field
│   └── Project tree (sectioned)
│       ├── Project A   <local>   ~/code/foo
│       │   ├── Session "Refactor auth middleware"   CC  •  2m
│       │   ├── Session "Fix migration"              Cx  •  1h
│       │   └── + New chat in this project
│       ├── Project B   ssh://host  /srv/svc
│       │   └── ...
│       └── + New project
│
└── Detail (chat pane)
    ├── Toolbar
    │   ├── ◂ collapse sidebar
    │   ├── Session title (inline-edit)
    │   ├── Provider/Model picker      ← center or right
    │   ├── Approval mode segmented   [Auto | Ask | RO]
    │   └── ⋯ menu (rename, archive, copy id, export, open cwd)
    ├── Message list (virtualized scroll)
    └── Composer (multiline textarea + footer row)
```

## 实体定义

```
Profile        host + provider + configRoot + envOverlay + commandPath
Project        host + cwd + title + defaultProfileId
Session        projectId + profileId + vendorSessionId + model + title + lastEventAt
Message        sessionId + role + parts[]
Part           text | tool_call | tool_output | diff | approval | reasoning | image
```

- `vendorSessionId` 来自 Codex/Claude SDK，resume 时回填给 SDK
- `Profile` 默认就是"本机当前 shell 环境 + 默认 codex/claude 二进制"
- 多账号 = 多 Profile（不同 env、不同 configRoot 或不同 binary path）

## 三类核心特性的展示规则

### 1. Tool call
折叠卡片：
```
▸ 🔧 Bash  ·  3.2s  ·  exit 0
   $ rg "ANTHROPIC_BASE_URL" -l
   (展开后显示完整 args + stdout/stderr，>20 行折叠)
```
颜色：成功 muted；失败红色边；running 显示 spinner。

### 2. Diff / file edit
```
▸ ✏ src/auth/middleware.go    +12 -3
   (展开显示 unified diff，带语法高亮 + 行号)
```
点击文件名 → 在本机 cwd 下用默认编辑器打开（或在 SSH 项目下复制远端路径）。

### 3. Approval request
inline 卡片（不是 modal）：
```
┌────────────────────────────────────────────┐
│ ⚠ Codex 想运行：                            │
│   rm -rf node_modules                      │
│   在 ~/code/foo                            │
│                                            │
│  [ Deny ]  [ Approve once ]  [ Always ✓ ] │
└────────────────────────────────────────────┘
```
"Always" 写入该 Project 的 approval policy。

## 模型/Profile 切换

工具栏正中央放一个 segmented picker：

```
[ Codex · gpt-5  ▾ ]    [ Auto ▾ ]
```

点开下拉：
- 上半部分：当前 provider 的模型列表（按 profile 过滤）
- 下半部分：Profile 切换（"切换将开新会话"）

切换模型 = 下条消息生效（vendor 支持就 in-session 切，不支持就提示新建会话）。
切换 Profile = 强制新建会话。

## SSH Project

新建项目对话框：
```
○ Local folder      [ Browse… ]    /Users/me/code/foo
● SSH host          host:  prod-1
                    path:  /srv/api
                    profile: [ default-codex-on-prod ▾ ]
```

connection 状态点显示在 project 名旁：●绿 / ●黄(连接中) / ●红(掉线，悬浮显示原因)。

SSH 模式下，Helm 在远端启动 runner，所有 `~/.codex`/`~/.claude` 都用远端的。

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

## 空状态

- 无 project：sidebar 中央提示 "Add a folder or SSH host to begin"
- project 无 session：右侧大号 composer + 模型选择提示
- 拉取中：sidebar 项用 shimmer，右侧不阻塞

## Streaming UI

- assistant 消息：左侧 caret 闪烁，token 流式追加
- 工具调用：spinner → 完成后状态切换
- 顶部右上角小态：`● Running · 0:12` 显示用时与停止按钮
- 用户在 streaming 中再发 → 自动 cancel 前一次 turn（带 toast 确认 undo）

## 不做（MVP 外）

- skills 管理 UI（先靠 symlink 手工）
- plugin market / MCP installer
- computer use（v2）
- 团队协作 / 同步
- 内置 diff editor（先打开外部）

## 待决问题

1. 是否一开始就支持多窗口（每个窗口锁一个 project）？
2. 消息历史本地 cache 还是 lazy 从 vendor 拉？(倾向 lazy + 显存缓存)
3. 远端 runner 用什么传输？SSE / WebSocket over SSH tunnel / 纯 stdio over ssh exec？
4. 起一个真名（候选：Helm / Cockpit / Coda / Pilot / Bridge / Mariner / Bosun）
