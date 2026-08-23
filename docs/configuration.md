# Configuration

The first-run wizard is the recommended configuration path. It validates choices, shows a final review before mutation, and persists the result in the current azd environment. Advanced administrators can set the same values with `azd env set` before `azd up`.

## Safety and readiness settings

| Variable | Default | Meaning |
|---|---|---|
| `DEVICE_NOTIFICATION_SCOPE_MODE` | Wizard choice | `selected` requires at least one monitored user/group ID; `all` requires an explicit tenant-wide acknowledgement |
| `DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED` | `false` | Must be the exact value `true` when both monitored ID lists are empty |
| `DEVICE_NOTIFICATION_SETUP_COMPLETE` | `false` | Records that the first-run choices were saved; noninteractive provisioning requires it to be set explicitly |
| `DEVICE_NOTIFICATION_COLLECTION_ENABLED` | `false` | Keeps Graph polling paused until current delivery configuration has passed protected synthetic testing |
| `DEVICE_NOTIFICATION_ONBOARDING_STATUS` | Managed by setup | Progresses through `delivery-validation-required`, `delivery-tested`, and `enabled-awaiting-live-event-validation` |
| `DEVICE_NOTIFICATION_DELIVERY_TESTED` | Managed by test | Becomes `true` only after all three synthetic event types succeed on every selected route |
| `DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT` | Managed by test | SHA-256 binds proof to the exact routes, destinations, Function App, and workload identity |

An empty `monitoredUserIds` and empty `monitoredGroupIds` combination means all discovered users. The deployment fails closed unless `DEVICE_NOTIFICATION_SCOPE_MODE=all` and `DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED=true` were recorded through an explicit review.

Do not set `DEVICE_NOTIFICATION_COLLECTION_ENABLED=true` directly. Use [protected delivery testing](operations.md#validate-every-selected-delivery-path) and the enablement script so stale or missing proof fails closed.

## Routing

`DEVICE_NOTIFICATION_ROUTING_JSON` controls each event and audience independently. This conservative example limits the deployment to one user and one group, does not exclude any device class, and enables only administrator Teams delivery:

```json
{
  "events": {
    "deviceRegistered": {
      "user": [],
      "admin": ["teamsWebhook"]
    },
    "deviceEnrolled": {
      "user": [],
      "admin": ["teamsWebhook"]
    },
    "deviceNoncompliant": {
      "user": [],
      "admin": ["teamsWebhook"]
    }
  },
  "excludedOwnership": [],
  "excludedOperatingSystems": [],
  "monitoredUserIds": ["11111111-1111-4111-8111-111111111111"],
  "monitoredGroupIds": ["22222222-2222-4222-8222-222222222222"],
  "privilegedUserIds": [],
  "adminMentions": []
}
```

Valid transports are `teamsDm`, `teamsWebhook`, and `email`. An empty audience array disables delivery to that audience for that event. Every enabled transport must have its matching destination configured and tested.

`monitoredUserIds` and `privilegedUserIds` contain Entra user object IDs. `monitoredGroupIds` supports transitive membership and causes the runtime to receive `User.ReadBasic.All` and `GroupMember.Read.All`. Graph group checks run in batches of 20. Do not use hidden-membership groups because the additional `Member.Read.Hidden` permission is intentionally not granted.

`privilegedUserIds` elevates an owned event to high severity. `adminMentions` applies only to Teams Workflow cards and contains objects such as:

```json
{ "name": "Intune Operations", "upn": "intune-ops@contoso.com" }
```

Review exclusions carefully. Values in `excludedOwnership` and `excludedOperatingSystems` suppress matching events; they are not examples of recommended security policy. Use values exactly as returned by Graph and prove the filter with test fixtures before broad use.

## Destinations

| Variable | Required when | Purpose |
|---|---|---|
| `TEAMS_ADMIN_WEBHOOK_URL` | Any admin `teamsWebhook` route | Callback URL for one administrator channel or chat Workflow |
| `ADMIN_EMAIL_RECIPIENTS` | Any admin `email` route | Comma-separated administrator email addresses |
| `EMAIL_SENDER_UPN` | Any owner or admin `email` route | Shared mailbox authorized through Exchange Application RBAC |

For multiple administrator Teams destinations, keep fanout inside an administrator-owned Workflow. The callback URL is a credential. Although it is passed to ARM as a secure parameter, it remains readable to administrators who can read the local azd environment or Function App settings.

Email setup also records exact ownership metadata:

- `DEVICE_NOTIFICATION_EXCHANGE_CONFIGURED`
- `DEVICE_NOTIFICATION_EXCHANGE_SERVICE_PRINCIPAL_OWNERSHIP`
- `DEVICE_NOTIFICATION_EXCHANGE_SCOPE_OWNERSHIP`
- `DEVICE_NOTIFICATION_EXCHANGE_ASSIGNMENT_OWNERSHIP`
- the exact recorded scope and assignment names

Ownership values are `created` or `adopted`. Do not edit them to make teardown delete an object whose provenance has not been verified.

## First-run enrollment behavior

| Variable | Default | Effect |
|---|---|---|
| `ENROLLMENT_LOOKBACK_HOURS` | `0` | Baseline-only: existing managed devices do not generate enrollment notifications; valid values are 0 through 720 hours |

A positive value opts into a bounded backfill: on first observation, devices with an `enrolledDateTime` inside the lookback can produce enrollment events. Compliance state is always baselined first; later transitions into alerting states generate compliance events.

Use a small selected scope before enabling a positive backfill. Changing the lookback later does not recreate events already fingerprinted or recorded.

## Collection schedules

| Variable | Default | Meaning |
|---|---|---|
| `ENTRA_POLL_SCHEDULE` | `0 */5 * * * *` | Entra timer schedule in NCRONTAB format |
| `INTUNE_POLL_SCHEDULE` | `30 */15 * * * *` | Intune timer schedule in NCRONTAB format |
| `ENTRA_AUDIT_OVERLAP_MINUTES` | `15` | Overlap used to tolerate late directory-audit records |

Azure Functions NCRONTAB schedules use UTC unless the hosting configuration explicitly provides a supported time-zone setting. The overlap intentionally rereads records; immutable event fingerprints suppress duplicates.

## Quiet hours

Quiet hours can be added to the routing JSON:

```json
"quietHours": {
  "start": 22,
  "end": 7,
  "timeZone": "America/Los_Angeles"
}
```

Quiet hours suppress low-severity owner routes immediately. They do **not** defer or queue a message for delivery when quiet hours end. Administrator routes and elevated events continue. Use an IANA time-zone identifier and test daylight-saving transitions that matter to the organization.

## Noninteractive configuration

Automation must provide complete, validated settings before `azd up`. In particular, it must set `DEVICE_NOTIFICATION_SETUP_COMPLETE=true`, explicitly record selected scope and tenant-wide confirmation when applicable, and provide all destinations required by enabled routes.

Noninteractive collection enablement additionally requires:

- current `DEVICE_NOTIFICATION_DELIVERY_TESTED=true` and a matching `DEVICE_NOTIFICATION_DELIVERY_TEST_FINGERPRINT`; and
- `DEVICE_NOTIFICATION_ENABLE_CONFIRMATION=ENABLE SELECTED SCOPE` or `ENABLE ALL USERS`, exactly matching the effective scope.

The fingerprint is produced only by a complete `Test-NotificationDelivery.ps1` run. It is technical dispatch evidence but not proof of Graph event detection. Retain the actual Teams Workflow run, Teams message, email receipt, and later Graph-backed drill evidence outside the azd environment.

`Enable-NotificationCollection.ps1 -AllowUntestedDestination` is an emergency override for a destination that cannot be tested. Interactive use requires the additional exact phrase `ENABLE WITHOUT DELIVERY PROOF` and warns that events may be missed. Avoid the override for normal deployment and record the accepted risk when it is unavoidable.
