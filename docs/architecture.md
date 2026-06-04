# Architecture

Helm is a SwiftUI macOS app that coordinates local and SSH agent sessions while
leaving vendor-owned state in the vendor's normal locations.

## Core Ideas

- The UI is a thin rendering and orchestration layer.
- Claude and Codex integrations are isolated behind per-vendor adapters.
- Local projects run provider CLIs on the Mac.
- SSH projects run provider CLIs on the remote host and read remote session
  metadata over SSH.
- Helm-owned state lives in the macOS application support directory.

## Main Areas

- `Helm/Models/` defines projects, sessions, providers, models, profiles, and
  workflow state.
- `Helm/Profiles/` owns persistence, profile discovery, image manifests, and
  app support paths.
- `Helm/Adapters/` translates provider CLI and session-store behavior into
  Helm's internal message and event model.
- `Helm/Views/` contains the SwiftUI shell, sidebar, chat surface, composer,
  profile editors, and rendering components.

## State Boundaries

Vendor state remains outside the repository and outside Helm's source tree:

- Codex config and sessions usually live under `~/.codex`.
- Claude config and sessions usually live under `~/.claude`.
- SSH project metadata is mirrored to `~/.helm/sessions.json` on the remote
  host so another Helm client can list restorable sessions for that target.
- Helm app metadata lives under
  `~/Library/Application Support/dev.deng.helm/`.

## Network Boundaries

Helm talks to configured provider endpoints only for model catalog lookup. Agent
turns are executed by the configured Claude or Codex runtime, which may make its
own network requests according to the user's provider configuration.
