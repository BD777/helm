## Summary

-

## Validation

- [ ] `xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug -derivedDataPath build/DerivedData build`
- [ ] `./scripts/open-source-scan.sh`
- [ ] `git diff --check`
- [ ] UI/provider behavior validated when applicable

## Open Source Hygiene

- [ ] No credentials, private transcripts, local app state, or generated build artifacts are included
- [ ] Screenshots and logs are sanitized
- [ ] Documentation updated for user-facing behavior, setup, storage, or security changes
