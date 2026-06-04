# Security Policy

Helm is pre-1.0. Please avoid sharing secrets, private transcripts, or provider
tokens in public issues or pull requests.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting if it is enabled for the repository.
If it is not available, open a minimal public issue that describes the affected
area without including exploitable details or sensitive data, and ask for a
private follow-up channel.

## Sensitive Data

Helm can interact with:

- Provider API tokens and base URLs.
- Local `~/.codex` and `~/.claude` configuration.
- Remote SSH host configuration.
- Agent transcripts, tool outputs, file paths, and image attachments.

At the moment, provider tokens configured inside Helm are stored in plaintext
inside the app support JSON files. Keychain storage is planned but not yet
implemented.
