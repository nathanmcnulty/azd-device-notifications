# Configuration

Set environment values with `azd env set NAME VALUE` before `azd up` or `azd provision`.

## Routing

`DEVICE_NOTIFICATION_ROUTING_JSON` controls each audience independently:

```json
{
  "events": {
    "deviceRegistered": {
      "user": ["teamsDm", "email"],
      "admin": ["teamsWebhook"]
    },
    "deviceEnrolled": {
      "user": ["teamsDm"],
      "admin": ["teamsWebhook", "email"]
    },
    "deviceNoncompliant": {
      "user": ["teamsDm", "email"],
      "admin": ["teamsWebhook", "email"]
    }
  },
  "excludedOwnership": ["company"],
  "excludedOperatingSystems": ["AndroidForWork"],
  "monitoredUserIds": [],
  "monitoredGroupIds": [],
  "privilegedUserIds": [],
  "adminMentions": [
    { "name": "Intune Operations", "upn": "intune-ops@contoso.com" }
  ],
  "quietHours": {
    "start": 22,
    "end": 7,
    "timeZone": "America/Los_Angeles"
  }
}
```

Valid transports are `teamsDm`, `teamsWebhook`, and `email`. Empty arrays disable an audience for that event.

`monitoredUserIds` and `privilegedUserIds` contain Entra user object IDs. `monitoredGroupIds` supports transitive membership and adds `User.ReadBasic.All` plus `GroupMember.Read.All` only when configured; group checks are limited by Graph to batches of 20. Hidden-membership groups additionally require `Member.Read.Hidden`, which this template does not grant.

Privileged users elevate an event to high severity. Quiet hours suppress only low-severity end-user routes; admin delivery and elevated events continue. Teams mentions apply to admin Workflow cards and use UPNs supported by the Teams Workflow connection.

## Destinations

| Variable | Purpose |
|---|---|
| `TEAMS_ADMIN_WEBHOOK_URL` | Workflows callback URL for one configured admin channel or chat |
| `ADMIN_EMAIL_RECIPIENTS` | Comma-separated admin addresses |
| `EMAIL_SENDER_UPN` | Exchange shared mailbox used by Graph `sendMail` |

For multiple admin Teams locations, create one Workflow that fans out to the required chats/channels. The callback URL is stored as a secure ARM parameter and Function App secret setting; anyone able to read app settings can retrieve it.

## Collection

| Variable | Default |
|---|---|
| `ENTRA_POLL_SCHEDULE` | `0 */5 * * * *` |
| `INTUNE_POLL_SCHEDULE` | `30 */15 * * * *` |
| `ENTRA_AUDIT_OVERLAP_MINUTES` | `15` |
| `ENROLLMENT_LOOKBACK_HOURS` | `24` |
