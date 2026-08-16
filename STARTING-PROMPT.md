# Starting Prompt: azd-device-notifications

Build this repository into a private Azure Developer CLI (`azd`) template for Microsoft Entra and Intune device lifecycle notifications delivered primarily through Microsoft Teams.

## Product direction

Provide a focused notification and triage service for:

- New device registration in Microsoft Entra.
- New device enrollment in Intune.
- Device compliance state changes and compliance failures.
- Noncompliant devices approaching or exceeding remediation deadlines.
- Ownership changes, stale devices, duplicate device records, and enrollment failures.
- Optional device certificate or Defender onboarding signals when they can be correlated safely.

This is an alerting and workflow solution, not a replacement for Intune device inventory or compliance reporting. Notifications should be actionable, deduplicated, severity-aware, and linked to the relevant admin experience.

## Reference material

- `nathanmcnulty/nathanmcnulty/Entra/device-registration/notifications/` for existing device-registration notification assets and deployment concepts.
- `nathanmcnulty/nathanmcnulty/Entra/passkeys/notifications/` for event filtering, duplicate suppression, KQL, Logic App, and notification design.
- `nathanmcnulty/nathanmcnulty/Intune/DeviceInventory.ps1`, `DeviceQuery.ps1`, and `Fix-ComplianceSyncIssues.ps1` for device operations and edge cases.
- `nathanmcnulty/nathanmcnulty/Intune/Revoke-CloudPKIDeviceCertificatesByUser.ps1` for certificate/device lifecycle context.
- `nathanmcnulty/azd-entra-health-monitoring` for Teams notification and Logic App deployment patterns.
- `nathanmcnulty/azd-device-cleanup` for stale-device safeguards and cleanup boundaries.
- `nathanmcnulty/azd-emergency-access` for tenant-safe hooks, validation, and cleanup behavior.

## Expected implementation

Use `azure.yaml`, Bicep, and azd hooks. Prefer supported Microsoft Graph audit logs, directory events, Intune APIs, Azure Monitor, and Sentinel interfaces. Do not depend on browser cookies or undocumented portal APIs. Include:

- A Teams-first notification workflow with configurable channel, severity, mention, and escalation behavior.
- Correlation and deduplication across registration, enrollment, compliance, and sign-in/device events.
- Configuration for monitored groups, excluded device types, privileged users, grace periods, quiet hours, and notification suppression.
- Durable state for event fingerprints, compliance transitions, notification history, and acknowledged incidents.
- Least-privilege managed identity/app permissions, diagnostics, throttling handling, and explicit admin-consent documentation.
- Safe optional actions such as creating a ticket, requesting user remediation, or invoking a remediation webhook; no destructive device action by default.
- Fixtures and tests for registration, enrollment, compliance transitions, duplicate events, missing owners, and delayed audit records.

Start with three end-to-end scenarios: new device registration, new Intune enrollment, and a device becoming noncompliant. Make the first deployment easy to validate in a test tenant and document licensing, retention, privacy, and Teams setup.