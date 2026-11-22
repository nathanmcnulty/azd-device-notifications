# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub's **Report a vulnerability** flow on this repository's Security tab. Do not open a public issue containing a Teams Workflow callback URL, access token, tenant identifier, user or device information, Teams conversation reference, email address, or notification content.

Include the affected event type and transport, deployment phase, reproducible behavior, expected security boundary, and suggested mitigation when available. Redact identifiers and secrets from logs before attaching them. If private reporting is unavailable, contact the maintainer through the public GitHub profile with only the minimum detail needed to establish contact.

Treat any exposed Workflow callback URL, Function key, or authentication material as compromised and rotate or revoke it before submitting the report. This project uses managed identity and is designed not to persist client secrets, storage keys, Function keys, delegated user tokens, raw Graph audit records, or full Intune inventory.

## Supported versions

The latest published stable release is `v1.0.0`. The default `main` branch is the only line currently used to prepare security fixes; no separate release branches receive backports. Future releases will identify their supported versions and fix policy in release notes. The published `v1.0.0` tag will not be changed.

## Response targets

This project is maintained by one person. The maintainer aims to acknowledge a private report within 7 calendar days and provide an initial triage or next-steps decision within 14 calendar days. These are targets, not a guarantee of emergency staffing or remediation time.

## Safe disclosure

Keep vulnerability details private until impact has been assessed and a fix, mitigation, or coordinated disclosure decision is available. Do not publish callback URLs, Function keys, access tokens, tenant identifiers, email addresses, Teams conversation references, user or device details, notification content, raw Graph audit records, full Intune inventory, or unredacted logs in public issues, pull requests, examples, or release bundles.
