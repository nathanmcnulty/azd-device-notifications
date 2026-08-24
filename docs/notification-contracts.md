# Notification contracts

This solution consumes the version 1 notification envelope and delivery-result schemas from `azd-reference`. The exact reference revision and SHA-256 hashes are pinned in `azd-components.lock.json`. These are portable wire contracts, not a shared renderer, dispatcher, authorization layer, or infrastructure module; Teams cards, email content, Graph authorization, and destination configuration remain owned by this solution.

## Event normalization

The dispatcher normalizes a queued device event before it evaluates routes:

| Solution event | Contract event type | Source |
| --- | --- | --- |
| `deviceRegistered` | `entra.device.registered` | `microsoftGraph.directoryAudit` |
| `deviceEnrolled` | `intune.device.enrolled` | `microsoftGraph.deviceManagement` |
| `deviceNoncompliant` | `intune.device.complianceChanged` | `microsoftGraph.deviceManagement` |

The contract preserves the stable solution event ID. A directory-audit Graph correlation ID is preserved when present; all other events use the event ID as their correlation ID. Protected synthetic delivery events set `isTest` to `true`. Environment metadata includes the azd environment name, tenant ID, subscription ID, and resource group.

Envelope `data` contains the bounded device, actor, owner, and compliance values needed by the existing solution-owned renderers. It can contain personal data and is never logged as a whole. Only the safe delivery result is written to administrator-facing logs.

## Route results and idempotency

| Solution route | Contract route ID | Contract transport |
| --- | --- | --- |
| User `teamsDm` | `user-teams-dm` | `teams.bot` |
| Admin `teamsWebhook` | `admin-teams-workflow` | `teams.workflowWebhook` |
| User `email` | `user-email` | `email.graph` |
| Admin `email` | `admin-email` | `email.graph` |

Every evaluated route emits one `AZD_NOTIFICATION_DELIVERY_RESULT` record. The canonical idempotency key is lowercase SHA-256 over UTF-8 text:

```text
tenantId + "\n" + eventType + "\n" + eventId + "\n" + route.id
```

New reservations use this canonical key. During migration, the history repository also checks the prior `eventId:audience:transport` hash and treats a delivered legacy record as `alreadyDelivered`; it never creates new legacy reservations.

Outcomes map as follows:

- accepted delivery: `succeeded`, attempt 1;
- canonical or legacy delivered history: `alreadyDelivered`, attempt 0;
- an active concurrent reservation: `skipped` with `concurrentDelivery`, attempt 0;
- a missing recipient or permanent provider outcome: `failed` with `destinationUnavailable` and `retryable: false`;
- a transport, provider, reservation, or history failure requiring queue retry: `failed` with `transientProvider` and `retryable: true`.

The synthetic endpoint continues to return its existing aggregate summary so the onboarding scripts retain their current success and failure checks. Contract results add route-level operational evidence in Function logs without exposing destinations, recipients, cards, payload data, webhook URLs, tokens, provider response bodies, or raw exceptions.

## Provision before a code-only deployment

The Function now requires `AZURE_ENV_NAME`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and `AZURE_RESOURCE_GROUP`. Existing environments must run `azd provision` (or a complete `azd up`) from a version containing these infrastructure settings before `azd deploy notifier`. A code-only deployment against older infrastructure fails closed at Function startup because it cannot emit schema-valid environment metadata.
