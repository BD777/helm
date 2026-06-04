# Security Policy

Helm is pre-1.0. Please avoid sharing secrets, private transcripts, or provider
tokens in public issues or pull requests.

The most important current limitation is token storage: provider tokens
configured inside Helm are stored in plaintext in app support JSON files.
Keychain storage is planned but not yet implemented.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting if it is enabled for the repository.
If it is not available, open a minimal public issue that describes the affected
area without including exploitable details or sensitive data, and ask for a
private follow-up channel.

Do not post exploit details, credentials, private transcripts, SSH hostnames, or
provider configuration in public issues.

## Sensitive Data

Helm can interact with:

- Provider API tokens and base URLs.
- Local `~/.codex` and `~/.claude` configuration.
- Remote SSH host configuration.
- Agent transcripts, tool outputs, file paths, and image attachments.

Run the repository hygiene scan before publishing code or release artifacts:

```bash
./scripts/open-source-scan.sh
```

The scan catches common high-risk secret patterns and internal-only terms in
the current tree, plus common high-risk secret patterns in git history. It is a
guardrail, not a substitute for reviewing logs, screenshots, transcripts, and
release archives.
