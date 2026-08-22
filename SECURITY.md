# Security policy

Report vulnerabilities privately through GitHub's security advisory workflow for this repository. Do not open a public issue containing a Teams Workflow callback URL, access token, tenant identifier, user or device information, Teams conversation reference, email address, or notification content.

Include the affected event type and transport, deployment phase, reproducible behavior, expected security boundary, and suggested mitigation when available. Redact identifiers and secrets from logs before attaching them.

Treat any exposed Workflow callback URL, Function key, or authentication material as compromised and rotate or revoke it before submitting the report. This project uses managed identity and is designed not to persist client secrets, storage keys, Function keys, delegated user tokens, raw Graph audit records, or full Intune inventory.

Until a stable version is released, only the current default branch is maintained. After releases begin, supported versions and security fixes will be identified in release notes.
