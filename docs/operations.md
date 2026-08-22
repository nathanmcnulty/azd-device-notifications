# Operations

## Deployment states

Use these checkpoints when handing the solution to another administrator:

1. **Foundation ready:** Azure resources are running and required Graph roles are assigned.
2. **Delivery validation required:** Teams and Exchange onboarding is incomplete or lacks proof. Collection remains disabled.
3. **Delivery tested:** all three protected synthetic event types passed every selected route and the exact configuration fingerprint was recorded. Collection remains disabled.
4. **Collection enabled, live validation required:** collection is enabled and real Graph-backed event drills remain outstanding.
5. **End-to-end validated:** an approved event of each enabled type was detected, queued, delivered, and recorded.

Do not describe the deployment as operational at checkpoint 1.

## Validate every selected delivery path

Record the date, test identity, audience, transport, expected destination, actual result, and related Workflow/Function evidence for every enabled route.

Keep collection paused and run all three event types through the deployed Function's protected synthetic endpoint:

```powershell
./scripts/Test-Deployment.ps1
./scripts/Test-NotificationDelivery.ps1
```

When owner routes are enabled, provide a prepared test user's Entra object ID, UPN, and email address at the prompts. The user must be directly selected, belong to a selected monitored group, or be covered by the explicitly confirmed all-users scope. You can also provide the values explicitly:

```powershell
./scripts/Test-NotificationDelivery.ps1 `
    -TestUserId <entra-user-object-id> `
    -TestUserUpn test-user@contoso.com `
    -TestUserEmail test-user@contoso.com
```

The script obtains a Function host key without printing it, calls only the test endpoint, and clears the key reference afterward. The endpoint refuses testing when either the azd environment or live Function setting says collection is enabled. Messages are labeled `[TEST]` and use the normal route dispatcher and delivery-history path.

A complete default run tests `deviceRegistered`, `deviceEnrolled`, and `deviceNoncompliant`, then records `DEVICE_NOTIFICATION_DELIVERY_TESTED=true` plus a SHA-256 fingerprint of the exact routing and destinations. Testing only selected `-EventType` values is useful for diagnosis but does not record enablement proof.

### Teams Workflow

Confirm every synthetic administrator event has a `Succeeded` Workflow run and a `[TEST]` card in the intended channel/chat. Function or Workflow HTTP success alone is insufficient.

### Teams personal message

For the prepared test recipient:

1. Confirm the approved app is installed in personal scope.
2. Confirm the bot received the installation activity and stored a conversation reference for that Entra object ID.
3. Run the synthetic test with that user's exact object ID, UPN, and email.
4. Confirm all expected `[TEST]` cards arrive in that user's personal chat and matching successful deliveries appear in `DeviceNotificationHistory`.

Installing the app is not delivery proof. A missing conversation reference makes the synthetic proof fail; correct the installation and rerun the complete test before enablement. After collection begins, an unavailable personal route may not be retried, which is why pre-enable proof is required.

### Shared-mailbox email

1. Run `Test-ServicePrincipalAuthorization` for the configured sender and confirm `Application Mail.Send` is `InScope=True`.
2. Test an unrelated mailbox and confirm it is not in scope.
3. Run the synthetic test for every configured owner/admin email audience.
4. Confirm final receipt of every expected `[TEST]` message, sender identity, intended recipients, and corresponding successful delivery-history records.

Graph `202 Accepted` is not final-delivery proof. Check Exchange message trace when acceptance succeeds but the message does not arrive.

## End-to-end test tenant validation

Start with `DEVICE_NOTIFICATION_SCOPE_MODE=selected` and dedicated test identities or a test group.

1. Complete synthetic proof for every selected path and inspect the actual Teams/email results.
2. Run `./scripts/Enable-NotificationCollection.ps1` and approve its exact scope and backfill review.
3. Register a test device and wait through the five-minute Entra polling interval plus ingestion delay.
4. Enroll a new Intune test device. A baseline-only deployment uses a zero-hour lookback; test enrollment detection with a deliberate positive lookback only in a bounded test scope.
5. Apply an approved test compliance policy that moves the device from its recorded baseline to an alerting state.
6. Confirm owner and administrator routes independently for each real event; synthetic success does not prove these Graph-backed paths.
7. Review Function logs and the following tables in the storage account:
   - `DeviceNotificationState` for watermarks, snapshots, and Teams conversations;
   - `DeviceEventFingerprints` for normalized event reservations;
   - `DeviceNotificationHistory` for successful audience/transport deliveries.
8. Confirm no unexpected message exists in `device-notifications-poison`.

Expected behavior:

- the first compliance observation establishes state without compliance-transition noise;
- a zero-hour enrollment lookback suppresses enrollment backfill;
- replayed or delayed audits are deduplicated by immutable audit ID;
- missing owners skip owner routes but do not inherently prevent administrator routes;
- monitored-group filtering suppresses an event when membership cannot be established;
- `unknown`, `error`, and `inGracePeriod` remain distinct compliance states.

## Troubleshooting

### Setup or Graph assignment returns 403

Azure Owner does not grant Microsoft Graph authority. Confirm the selected tenant, activate Privileged Role Administrator, authenticate again through the normal broker/browser flow if required, and rerun `azd up`. Allow for service-principal and app-role propagation before treating an immediate retry as a permanent failure.

### Collection remains disabled

This is expected until scope is explicit, every route has its required destination, and the exact configuration has passed a complete synthetic test. Review:

```powershell
azd env get-value DEVICE_NOTIFICATION_SCOPE_MODE
azd env get-value DEVICE_NOTIFICATION_TENANT_WIDE_CONFIRMED
azd env get-value DEVICE_NOTIFICATION_ONBOARDING_STATUS
azd env get-value DEVICE_NOTIFICATION_DELIVERY_TESTED
azd env get-value DEVICE_NOTIFICATION_COLLECTION_ENABLED
```

Do not force the collection flag merely to clear the status. Correct the readiness issue, run `./scripts/Test-Deployment.ps1` and `./scripts/Test-NotificationDelivery.ps1`, inspect the delivered messages, and then use `./scripts/Enable-NotificationCollection.ps1`.

`-AllowUntestedDestination` is an explicit last-resort override. It requires an additional warning acknowledgement and accepts that events may be missed. Do not use it to avoid diagnosing a normal setup failure.

### Teams personal delivery says no conversation exists

Confirm the app package belongs to the current azd environment, the app is approved and permitted, and it is installed in **personal** scope for the exact recipient. Check Function logs for the installation activity. Reinstall only after confirming app policy propagation. Events consumed before the conversation existed may need a new approved test event.

### Teams Workflow returns 401, 404, or 410

Confirm the callback belongs to the intended active Workflow and was copied in full. Inspect Workflow ownership, connection authorization, destination access, and run history. If the URL was rotated, update `TEAMS_ADMIN_WEBHOOK_URL`, rerun `azd provision`, and retest. Treat an exposed URL as compromised.

### Email returns `ErrorAccessDenied`

Confirm the Exchange service-principal pointer references the current managed identity, the management scope resolves exclusively to the sender, and the role assignment uses `Application Mail.Send`. Rerun `Test-ServicePrincipalAuthorization`; allow for Exchange propagation and do not compensate by granting tenant-wide Entra `Mail.Send`.

### Group-scoped events are suppressed

Confirm the subject is a user, the configured IDs are Entra group object IDs, and transitive membership is present. Hidden-membership groups require a permission the template intentionally does not grant. Graph checks are batched in groups of 20.

### Timers appear late or duplicate reads occur

Schedules use Azure Functions NCRONTAB semantics and normally run in UTC. The Entra overlap deliberately rereads recent audits to tolerate ingestion delay; fingerprints suppress duplicate events. Check Function timer status and Application Insights before changing schedules.

### Messages enter the poison queue

Inspect the original event and each route's Function error before replay. Correct the destination or permission first. Preserve the poison message as evidence, then use an approved, documented replay procedure; arbitrary reinsertion can create duplicate external messages.

## Routine maintenance

- Test every selected route and one end-to-end event on an organizationally approved schedule.
- Review managed-identity Graph permissions and Exchange mailbox scope after configuration changes.
- Review Workflow owner/co-owner status and connection health.
- Confirm the Teams app remains approved and installed for the intended scope.
- Monitor Function failures, queue depth, poison messages, and unexpected growth in state/history tables.
- Review Azure cost and Log Analytics ingestion.
- Export required audit evidence and run the approved data-purge process.

## Teardown

Teardown has Azure, Exchange, and Teams ownership boundaries. Export required history before deleting storage.

### 1. Pause collection

```powershell
azd env set DEVICE_NOTIFICATION_COLLECTION_ENABLED false
azd provision
```

Confirm the Function App setting is `false` before tenant cleanup.

Wait for active Function executions and queues to settle. Preserve poison messages and history required by policy.

### 2. Remove tenant-side configuration by ownership

- **Exchange:** preview ownership-aware cleanup with `./scripts/Remove-TenantObjects.ps1 -WhatIf`, then run `./scripts/Remove-TenantObjects.ps1`. It removes only the exact service-principal pointer, management scope, and role assignment recorded as `created` by this environment. Do not remove an `adopted` object without a separate administrator decision. Verify the role assignment is gone and the identity is no longer authorized for the mailbox.
- **Teams custom app:** remove setup-policy assignments and user installations created for this solution, then remove the uploaded custom app when it is not shared by another deployment.
- **Teams Workflow:** an administrator-owned Workflow is never deleted automatically. Disable/delete it or transfer ownership, remove obsolete connections, and rotate/revoke its callback URL.

Retain the azd environment until exact ownership records have been reviewed. Do not infer ownership from a display name alone.

When Exchange was configured, cleanup requires the ExchangeOnlineManagement module and an Exchange administrator authenticated to the exact azd tenant through the normal browser flow. If that safe cleanup cannot run, `azd down` stops before deleting the ownership evidence; it does not fall back to ambiguous deletion.

### 3. Remove Azure resources

```powershell
azd down --purge --force
```

The predown hook runs the same ownership-aware tenant cleanup before deleting the resource group, including notification state and history. If tenant cleanup cannot prove ownership, teardown stops rather than broadening deletion. Confirm the resource group and managed identity no longer exist. Finally, remove the local azd environment only after no ownership evidence is needed for tenant cleanup.
