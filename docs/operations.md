# Operations and validation

## Test tenant validation

1. Limit `monitoredUserIds` or `monitoredGroupIds` to test identities.
2. Install the Teams app for those users and verify the bot installation appears in Teams.
3. Register a test device and wait for the overlapping Entra poll.
4. Enroll a new Intune device within `ENROLLMENT_LOOKBACK_HOURS`.
5. Apply a test compliance policy that moves the device from its baseline state to noncompliant.
6. Confirm each configured owner and admin route independently.

Review Function logs and these tables in the storage account: `DeviceNotificationState`, `DeviceEventFingerprints`, and `DeviceNotificationHistory`. Failed queue messages move to `device-notifications-poison` after five attempts.

## Expected edge behavior

- Replayed or delayed audit rows are suppressed by the audit fingerprint.
- Initial Intune discovery does not create compliance-transition noise.
- Initial devices enrolled outside the lookback do not create enrollment noise.
- Missing owners skip owner routes but still permit admin routes unless monitored-user/group filtering requires a known subject.
- A missing Teams personal conversation fails that route but does not block admin/email attempts.
- Unknown and grace-period compliance states remain distinct.

## Throttling

Graph requests honor numeric `Retry-After` and retry 429 or 5xx responses with bounded exponential backoff. Pollers follow `@odata.nextLink`. Repeated delivery failures are visible in the poison queue and Application Insights.

## Teardown

`azd down` deletes Azure resources. Exchange Application RBAC objects are tenant-side configuration and are not deleted automatically. Remove the management role assignment, management scope, and Exchange service-principal pointer explicitly if retiring the service.
