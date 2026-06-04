# Development

## Build

```bash
xcodebuild -project Helm.xcodeproj \
  -scheme Helm \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  build
```

## Run

```bash
open build/DerivedData/Build/Products/Debug/Helm.app
```

When validating changes from inside another Helm session, launch and quit only
the debug app instance you started. Avoid broad process commands that could stop
someone else's Helm session.

## Regenerating the Project

`project.yml` is kept as a project definition. If you regenerate the Xcode
project, review the generated `Helm.xcodeproj/project.pbxproj` carefully before
committing.

## Release Helper

`rebuild-helm-app.command` builds a Release app from the configured remote
branch and installs it into `/Applications` by default:

```bash
./rebuild-helm-app.command
```

Useful environment overrides:

- `HELM_REMOTE`
- `HELM_BRANCH`
- `HELM_CONFIGURATION`
- `HELM_INSTALL_DIR`
- `HELM_KEEP_BUILD_ARTIFACTS`

The helper may quit or replace a running Helm app during installation.
