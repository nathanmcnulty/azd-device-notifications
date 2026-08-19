# Architecture and boundaries

## Collection

The Entra timer queries `GET /auditLogs/directoryAudits` every five minutes with a configurable overlap. It accepts successful `Register device` and `Add device` operations, finds device and user targets by type or properties rather than array position, and fingerprints the immutable audit ID.

The Intune timer queries `GET /deviceManagement/managedDevices` every 15 minutes. The first observation establishes a baseline. A recent `enrolledDateTime` can produce an enrollment notification; old devices do not flood the first deployment. Later compliance state differences produce transition events without collapsing `unknown`, `error`, and `inGracePeriod` into a boolean.

Registration actor, explicit owner, Entra device ID, and Intune managed-device ID remain distinct. When an audit has no explicit owner, the registering user is the end-user recipient while remaining identified as the actor. Registration and enrollment are separate lifecycle facts even when they correlate to the same Entra device ID.

## State and retries

- `DeviceNotificationState` stores watermarks, snapshots, and Teams conversation references.
- `DeviceEventFingerprints` reserves normalized events before queueing and suppresses overlapping audit polls.
- `DeviceNotificationHistory` records each event, audience, and transport delivery.
- `device-notifications` is the outbox. Azure Functions retries failed deliveries five times before moving them to the standard poison queue.

One failed route does not prevent other routes from running. Successful routes are recorded and skipped on retry. Stale pending event reservations are recovered after 15 minutes so a Function termination cannot permanently suppress an event. Delivery is at least once: a process termination after an external service accepts a message but before history is recorded can still produce a duplicate.

## Delivery

Teams personal messages use an Azure Bot with a user-assigned managed identity. The Teams app must be installed for the user; its installation activity supplies the supported conversation reference used for proactive messages. The service does not misuse Graph migration permissions or delegated user tokens.

Admin Teams delivery uses a Power Automate Workflows webhook bound to a configured channel or chat. Workflow ownership and its callback URL must be managed as credentials. Email uses Graph `sendMail` from one shared mailbox, authorized by Exchange Application RBAC rather than tenant-wide Entra `Mail.Send`.

## Current scope

This release completes the three requested end-to-end scenarios. Grace-deadline reminders, stale/duplicate/ownership/enrollment-failure events, ticket/remediation webhooks, acknowledgement workflows, and optional Defender or certificate enrichment are intentionally later phases. None requires a destructive device action.
