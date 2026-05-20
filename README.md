# Helm

Unified macOS client for Claude Code + Codex.

Thin SwiftUI GUI; backends are local/SSH Codex SDK or Claude Agent SDK via per-vendor adapters. Sessions, auth, and config live on the host running the agent (local `~/.codex` / `~/.claude` or the remote SSH machine), not copied into Helm.

## Status
Pre-MVP. Currently designing UI; see `design/`.

## Layout
- `design/` — mockups, UI notes, interaction states
- `docs/` — architecture, adapter protocol, session/index format
- `Helm/` — Xcode project (TBD)

## Working name
Locked: **Helm**.
