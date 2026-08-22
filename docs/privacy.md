# Privacy and retention

Review this data inventory and the organization's retention requirements before enabling tenant-wide collection.

## Stored data

The service stores only fields needed to correlate, route, and audit notifications:

- event IDs, fingerprints, types, and timestamps;
- device IDs/names, operating system, ownership, compliance state, and grace deadline;
- actor or owner object IDs, UPNs, display names, and email addresses when Graph supplies them;
- poll watermarks and managed-device snapshots;
- Teams conversation references, which include routing identifiers needed for proactive messages;
- audience/transport delivery keys and timestamps;
- queued and poison events awaiting delivery or investigation.

Raw Graph audit records and a full Intune inventory are not intentionally persisted. Application logs should contain operational metadata rather than message bodies, callback URLs, access tokens, or raw Graph responses. Treat unexpected sensitive log content as an incident and rotate any exposed credential.

## Processing boundaries

Azure Functions, Storage, Application Insights, and Log Analytics use the selected Azure deployment region. Microsoft Graph, Teams, Exchange Online, Azure Bot, and Power Automate process data within their normal service boundaries. Confirm that combination satisfies organizational residency and cross-service processing requirements.

The solution never takes destructive device action. Administrator links are generated only from validated GUIDs and lead to Microsoft administrative experiences where normal authorization still applies.

## Credentials and privileged configuration

The Teams Workflow callback URL is a credential. It is stored in the local ignored azd environment and in Function App configuration even though ARM receives it as a secure parameter. Restrict access to both locations, avoid terminal/log output, add durable Workflow co-owners, and rotate the URL after exposure or ownership change.

The Function uses managed identity and does not store a client secret. Shared-mailbox sent items are disabled (`saveToSentItems` is `false`), but Exchange transport and recipient systems retain their normal message-trace and mailbox records. Notification history stores delivery metadata rather than message bodies.

The protected synthetic-delivery script retrieves a Function host key only while collection is paused, sends it in the `x-functions-key` header, never intentionally prints it, and clears its in-process reference. Treat terminal tracing, transcripts, or custom modifications that expose the key as a credential incident.

## Current retention behavior

Application Insights and Log Analytics are configured for 30 days. Native Entra audit availability depends on tenant licensing and current Microsoft service policy.

Azure Table entities used for watermarks, snapshots, event fingerprints, Teams conversations, and delivery history do not currently have an application-enforced expiration policy. They remain until an administrator purges them or deletes the storage account. Do not assume a generic Storage lifecycle rule expires Table entities. Queue and poison-message behavior must also be included in the organization's operational retention review.

This makes the default state retention the lifetime of the deployment. If policy requires a shorter period, keep collection disabled until an approved bounded purge process is in place.

## Operational privacy tasks

- Limit `monitoredUserIds` or `monitoredGroupIds` during validation. Empty lists require explicit acknowledgement because they mean all discovered users.
- Export only the minimum delivery history required for audit, and protect object IDs/UPNs in that export.
- Remove a departed user's Teams app installation and conversation reference through the approved purge/offboarding process.
- Purge obsolete snapshots, fingerprints, history, and poison events on an organizationally defined schedule.
- Review Application Insights sampling and diagnostic settings after adding any custom logging.
- Include the Workflow owner, Exchange sender, and downstream Teams/email retention in privacy assessments.

## Teardown and deletion

`azd down --purge --force` deletes the Azure resource group and therefore the storage account containing state and notification history. Export required evidence first. Azure teardown does not automatically delete administrator-owned Teams Workflows, Teams messages, email already delivered to recipients, or adopted tenant-side configuration.

Follow the ownership-aware [teardown checklist](operations.md#teardown). Retain the local azd environment until its exact ownership records are no longer required; then remove it through the normal azd environment workflow and handle any backups according to organizational policy.
