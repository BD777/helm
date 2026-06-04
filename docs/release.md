# Release Notes

Helm is currently source-build first. The checked-in rebuild script is useful
for local installs, but it does not produce a public, notarized macOS release.

## Local Rebuild

For a local Release build and `/Applications` install:

```bash
./rebuild-helm-app.command
```

The script fetches the configured remote branch, builds `Helm.app`, may quit a
running Helm instance, removes older local copies it finds, and installs the new
app into `/Applications` by default.

Useful environment overrides:

```bash
HELM_BRANCH=main ./rebuild-helm-app.command
HELM_INSTALL_DIR="$HOME/Applications" ./rebuild-helm-app.command
HELM_SKIP_INSTALL=1 HELM_KEEP_BUILD_ARTIFACTS=1 ./rebuild-helm-app.command
```

## Public Binary Release Checklist

Before publishing a downloadable app bundle:

- Build from a clean, tagged commit on `main`.
- Run CI, `git diff --check`, and `./scripts/open-source-scan.sh`.
- Use a Developer ID Application certificate instead of ad-hoc signing.
- Enable hardened runtime with the entitlements the app actually needs.
- Notarize the archive with Apple and staple the notarization ticket.
- Include `LICENSE`, `THIRD_PARTY_NOTICES.md`, and release notes.
- Publish checksums for downloadable archives.
- Mention that provider CLIs, authentication, and user data remain outside the
  app bundle.

Until that flow exists, public users should build from source.
