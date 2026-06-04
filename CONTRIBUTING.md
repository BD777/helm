# Contributing

Thanks for helping make Helm better.

## Development Setup

1. Install Xcode with the macOS SDK.
2. Clone the repository.
3. Build the app:

   ```bash
   xcodebuild -project Helm.xcodeproj \
     -scheme Helm \
     -configuration Debug \
     -derivedDataPath build/DerivedData \
     build
   ```

4. Run the debug build from `build/DerivedData/Build/Products/Debug/Helm.app`.

Claude Code and Codex are optional at build time, but at least one configured
provider is needed to exercise real agent sessions.

## Pull Requests

- Keep changes focused and consistent with the existing SwiftUI patterns.
- Update README or docs when behavior, storage, permissions, or setup changes.
- Do not commit local app state, generated worktrees, build outputs, logs,
  credentials, tokens, session transcripts, or screenshots containing private
  data.
- Run `git diff --check` before opening a pull request.
- For UI or provider changes, include the validation you performed in the pull
  request description.

## Validation

For most changes, run:

```bash
xcodebuild -project Helm.xcodeproj \
  -scheme Helm \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  build
git diff --check
```

Provider, SSH, approval, and Computer Use changes should also be validated in a
real debug app session because direct CLI calls do not prove Helm's UI and
transcript behavior.
