# Helm

Unified macOS client for Claude Code + Codex.

Thin SwiftUI GUI; backends are local/SSH Codex SDK or Claude Agent SDK via per-vendor adapters. Agent transcripts, auth, and config live on the host running the agent (local `~/.codex` / `~/.claude` or the remote SSH machine). Helm keeps its app state in macOS app support and mirrors restorable session metadata to the target machine's `~/.helm/sessions.json` so another Helm client can list sessions for the same target.

## Status
Pre-MVP. Currently designing UI; see `design/`.

## Layout
- `design/` — mockups, UI notes, interaction states
- `docs/` — architecture, adapter protocol, session/index format
- `Helm/` — Xcode project (TBD)

## Working name
Locked: **Helm**.
