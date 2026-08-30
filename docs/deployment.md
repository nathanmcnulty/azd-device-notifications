# Deployment

Deployment is intentionally phased. The first `azd up` creates and validates the Azure foundation with collection paused. Finish and prove the selected destinations before enabling Graph polling.

## 1. Prepare the administrator session

Install Azure CLI, Azure Developer CLI 1.23 or later, and PowerShell 7. Email setup additionally requires the ExchangeOnlineManagement PowerShell module. Administrators do not install Node.js or npm: the repository contains the ready-to-run Function package, including its application dependencies, and deployment performs no local or remote npm restore or source build.

If an administrator Teams Workflow route will be selected, create **Post to a chat or channel when a webhook request is received** now, choose the intended destination, add a durable co-owner, and copy the callback URL. The first-run wizard requires and validates that credential before it enables the route.

Use an account with the roles listed in [identity and permissions](identity-and-permissions.md). Confirm that the Azure CLI is signed in to the intended tenant and subscription through its normal broker or browser flow:

```powershell
az account show --query '{tenant:tenantId,subscription:id,name:name}'
azd auth login
```

Do not use device-code authentication. The preprovision guard stops when the active Azure CLI tenant, subscription tenant, and azd tenant do not match.

Use a fresh azd environment name. Preprovision refuses an existing `rg-<environment-name>` unless the same local environment recorded its creation and its exact ownership tags still match; there is no implicit Azure resource-group adoption.

## 2. Initialize and review choices

Until the first stable release is published, use the default branch only for review and test deployments:

```powershell
azd init --template nathanmcnulty/azd-device-notifications
azd up
```

The first-run review covers:

- selected users/groups or an explicitly acknowledged all-users scope;
- owner and administrator routes for each event;
- required Teams Workflow, administrator email, and shared-mailbox values;
- an enrollment lookback, where `0` is the recommended baseline-only first run;
- a final summary before tenant or Azure changes.

Choices are saved in the azd environment. An interrupted or incomplete onboarding resumes and revalidates those choices. Advanced administrators can configure the same environment values described in [configuration](configuration.md).

After the first stable release, production initialization should pin that release rather than follow `main`:

```powershell
azd init --template nathanmcnulty/azd-device-notifications --branch v1.0.0
```

## 3. Confirm foundation readiness

The initial deployment uploads the reviewed Function package already contained in the repository, with remote build disabled. It should report the Function App state and exact core Graph application-role assignments. When personal Teams messages are selected, it also creates `teams-app/device-notifications.zip`.

When upgrading an existing environment to a version that includes notification contracts, run `azd provision` before any code-only `azd deploy notifier`. Provisioning adds the environment metadata required for schema-valid delivery results; deploying the Function first causes startup to fail closed. See [Notification contracts](notification-contracts.md#provision-before-a-code-only-deployment).

At this point `DEVICE_NOTIFICATION_COLLECTION_ENABLED` remains `false`. This is expected: a running Function App and assigned Graph permissions prove infrastructure readiness, not message delivery. Finish every selected destination below.

## 4. Verify a Teams Workflow

Use these steps only when an administrator `teamsWebhook` route is selected:

1. Confirm the callback entered during the wizard still belongs to the intended chat or standard/shared channel. Check current Microsoft support before using a private channel.
2. Confirm the Workflow uses a durable organizational connection and has at least one co-owner.
3. If the callback must be changed, treat it as a credential and update the environment before reprovisioning:

   ```powershell
   azd env set TEAMS_ADMIN_WEBHOOK_URL '<callback-url>'
   azd provision
   ```

4. Submit the harmless validation payload described in [operations](operations.md#validate-every-selected-delivery-path).
5. Confirm both `Succeeded` in the Workflow run history and the expected card in the intended destination.

Legacy Office 365 connectors are not used. The callback URL is held in the local ignored azd environment and in Function App configuration; anyone who can read either location can replay it.

## 5. Configure Teams personal messages

Use these steps only when a `teamsDm` route is selected:

1. In the Teams admin center, upload `teams-app/device-notifications.zip` as a custom app.
2. Review and approve the app, then ensure custom apps are permitted for the intended test users.
3. Install the app in personal scope for each intended test recipient, either directly or through an administrator-owned setup policy.
4. Wait for policy/install propagation and confirm the installation activity reaches the bot. That activity supplies the conversation reference required for proactive delivery.
5. Run the personal-message validation in [operations](operations.md#validate-every-selected-delivery-path) for every test recipient.

Do not grant the workload broad Teams app-installation permission. Administrator-owned app setup policies can scale installation after the test group succeeds.

## 6. Configure shared-mailbox email

Use these steps only when an `email` route is selected. Do not grant the managed identity the Entra `Mail.Send` application role, which would permit sending as every mailbox.

During interactive `azd up`, postprovision connects through the normal Exchange Online browser flow and configures mailbox-scoped Application RBAC automatically. If that step was interrupted or the sender mailbox changes, repair it with:

```powershell
./scripts/Configure-ExchangeMail.ps1 `
    -SenderMailbox notifications@contoso.com `
    -AdminUpn exchange-admin@contoso.com
azd provision
```

The script disconnects other Exchange sessions, opens one connection for the exact administrator UPN, and verifies that connection's tenant and user before mutation. It creates an Exchange service-principal pointer, a recipient scope that resolves only to the requested mailbox, and an `Application Mail.Send` management-role assignment. Exact target intent and per-object `create-pending` checkpoints are recorded before mutation so an interrupted setup remains cleanable.

If exact matching objects already exist but have no creation receipt in this azd environment, setup stops. After independently verifying their provenance and exact app, principal, scope, role, and mailbox binding, explicitly opt in with `-AdoptExisting`. Adopted objects are recorded but never removed by automated teardown.

Before continuing:

1. Confirm `Test-ServicePrincipalAuthorization` reports `Application Mail.Send` with `InScope` equal to `True` for the selected mailbox.
2. Confirm the same identity is not in scope for an unrelated mailbox.
3. Send a harmless test and confirm final receipt. A Graph `202 Accepted` response proves only that Exchange accepted the request for processing.

## 7. Validate and enable collection

Follow [validate every selected delivery path](operations.md#validate-every-selected-delivery-path). Do not mark setup complete based only on resource state or an HTTP acceptance response.

With collection still paused, rerun infrastructure/configuration validation and send all three protected synthetic event types through the normal dispatch path:

```powershell
./scripts/Test-Deployment.ps1
./scripts/Test-Deployment.ps1 -TestDelivery
```

Owner routes prompt for a prepared test user's object ID, UPN, and email address. Confirm every expected `[TEST]` Teams card and email reaches its intended recipient. A complete run records a fingerprint of the exact routes and destinations.

Then start the interactive enablement review:

```powershell
./scripts/Enable-NotificationCollection.ps1
```

The enablement script revalidates configuration, tenant context, and the proof fingerprint, then requires exact confirmation of the saved scope and enrollment backfill before it changes the Function App setting. It sets onboarding to `enabled-awaiting-live-event-validation`.

Finally, induce one approved Graph-backed test event of each enabled type and confirm detection, queueing, delivery, and history independently. Synthetic tests prove dispatch only; they do not prove Graph polling, timer execution, normalization, or ingestion delay.

## Licensing and service ownership

- An active Intune subscription is required; managed users and devices need licensing appropriate to their management scenario.
- Teams recipients need Teams enabled and organizational policy must permit the custom app. Power Platform ownership and request limits apply to Workflows.
- The sender must be a usable Exchange Online shared mailbox. Applicable mailbox licensing, storage, and feature limits still apply.
- Entra audit-log availability and retention depend on the tenant license. Export logs through an approved organizational process when longer retention is required.

Treat these as predeployment checks rather than permanent product guarantees; verify current Microsoft licensing and channel support for the target tenant.
