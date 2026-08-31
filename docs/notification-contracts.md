# Notification contracts

This solution consumes the version 1 notification envelope and delivery-result schemas from `azd-reference`. The exact reference revision and SHA-256 hashes are pinned in `azd-components.lock.json`. These are portable wire contracts, not a shared renderer, dispatcher, authorization layer, or infrastructure module; Teams cards, email content, Graph authorization, and destination configuration remain owned by this solution.

## Event normalization

The dispatcher normalizes a queued device event before it evaluates routes:

| Solution event | Contract event type | Source |
| --- | --- | --- |
| `deviceRegistered` | `entra.device.registered` | `microsoftGraph.directoryAudit` |
| `deviceEnrolled` | `intune.device.enrolled` | `microsoftGraph.deviceManagement` |
| `deviceNoncompliant` | `intune.device.complianceChanged` | `microsoftGraph.deviceManagement` |

The contract preserves the stable solution event ID. A directory-audit Graph correlation ID is preserved when present; all other events use the event ID as their correlation ID. Parseable occurrence times are emitted through `Date.toISOString()` so even date-only or timezone-less inputs become RFC3339 UTC values; unparseable values fail before routing. Protected synthetic delivery events set `isTest` to `true`. Environment metadata includes the azd environment name, tenant ID, subscription ID, and resource group.

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

New reservations use this canonical key. During migration, the history repository also checks the prior `eventId:audience:transport` hash. A delivered legacy record becomes `alreadyDelivered`, and a fresh pending legacy reservation becomes `skipped` with `concurrentDelivery`; new legacy reservations are never created. Freshness uses the same two-minute threshold as canonical reservations.

The fallback cannot make the two independent row keys transactional. After a legacy pending reservation becomes stale, a new worker may create the canonical reservation while an old worker is still capable of completing the legacy row. That residual cross-key cutover race retains the solution's documented at-least-once duplicate risk. For upgrades, pause collection, allow queued and active legacy deliveries to drain, then provision and deploy the new version before resuming collection.

Outcomes map as follows:

- accepted delivery: `succeeded`, attempt 1;
- canonical or legacy delivered history: `alreadyDelivered`, attempt 0;
- an active concurrent reservation: `skipped` with `concurrentDelivery`, attempt 0;
- HTTP 400: `invalidRequest`, non-retryable;
- HTTP 401: `authentication`, non-retryable;
- HTTP 403: `authorization`, non-retryable;
- HTTP 404 or 410, a missing recipient, or a permanent Teams bot outcome: `destinationUnavailable`, non-retryable;
- HTTP 408: `timeout`, retryable;
- HTTP 429: `throttled`, retryable;
- HTTP 5xx: `transientProvider`, retryable;
- a transport or state failure without safe status metadata: `unknown`, retryable; other unclassified HTTP responses are `unknown` and non-retryable.

The synthetic endpoint continues to return its existing aggregate summary so the onboarding scripts retain their current success and failure checks. Contract results add route-level operational evidence in Function logs without exposing destinations, recipients, cards, payload data, webhook URLs, tokens, provider response bodies, or raw exceptions.

## Provision before a code-only deployment

The Function now requires `AZURE_ENV_NAME`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and `AZURE_RESOURCE_GROUP`. Existing environments must run `azd provision` (or a complete `azd up`) from a version containing these infrastructure settings before `azd deploy notifier`. A code-only deployment against older infrastructure fails closed at Function startup because it cannot emit schema-valid environment metadata.

## Pilot integration sequencing

This pilot is stacked on deployment-validation PR #9. Graph continuation hardening PR #10 is a merge prerequisite: merge it first, then rebase this branch and rerun the full offline suite. This branch adds only safe structured Graph failure metadata and intentionally does not copy PR #10's URL-validation change.
