# Privacy and Data Handling

Helm is designed to keep user data local to the machine or SSH host that runs
the agent.

## Stored Locally

Helm stores app state under:

```text
~/Library/Application Support/dev.deng.helm/
```

That directory can include profile metadata, provider configuration, image
attachment manifests, transcript snapshots, and project/session indexes.

Provider tokens configured inside Helm are currently stored in plaintext in app
support JSON files. Do not commit those files or share them in issue reports.

## Vendor State

Helm reads vendor-owned files from their normal locations:

- Codex: `~/.codex`
- Claude: `~/.claude`
- Remote session index: `~/.helm/sessions.json` on the SSH host

Helm does not copy those directories into the repository.

## Network Activity

The current app code does not include analytics or crash reporting integrations.
Helm performs direct model-catalog requests to configured provider endpoints
from the profile editor. Agent turns are run by the configured provider runtime,
which may contact its own service endpoints.

## Before Sharing Logs or Screenshots

Review for:

- API tokens and authorization headers.
- Provider base URLs.
- SSH hostnames and local file paths.
- Agent prompts, tool results, diffs, and transcript excerpts.
- Image attachments or screenshots that include private data.
