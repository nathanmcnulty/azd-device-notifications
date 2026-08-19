# Deployment and permissions

## Deployer requirements

The deployer needs permission to create resources and role assignments in the target subscription, normally Owner or Contributor plus User Access Administrator. The active Azure CLI tenant, subscription tenant, and azd tenant must match; the preprovision hook fails before Graph mutation if they do not.

Assigning Microsoft Graph application roles to the managed identity requires a sufficiently privileged Entra administrator, normally Privileged Role Administrator, and an Azure CLI token permitted to manage service-principal app-role assignments.

## Runtime permissions

The postprovision hook grants only:

- `AuditLog.Read.All`
- `DeviceManagementManagedDevices.Read.All`

When monitored groups are configured it also grants:

- `User.ReadBasic.All`
- `GroupMember.Read.All`

The template does not grant `Directory.Read.All`, any Intune write permission, `Teamwork.Migrate.All`, or Entra `Mail.Send`.

## Teams channel or chat

1. In Teams Workflows, create **Post to a chat or channel when a webhook request is received**.
2. Select the destination chat or standard/shared channel. Confirm current Microsoft support before targeting a private channel.
3. Add at least one co-owner and use a durable service account for the Teams connection.
4. Treat the generated callback URL as a secret.
5. Run `azd env set TEAMS_ADMIN_WEBHOOK_URL '<url>'` before provisioning.

Legacy Office 365 connectors are not used.

## Teams personal messages

`azd up` creates an Azure Bot and generates `teams-app/device-notifications.zip`. Upload it in the Teams admin center, approve it, and install it in personal scope for target users. A personal installation is required before proactive notification delivery. Tenant app permission and setup policies can automate installation without granting this workload permission to install arbitrary apps.

## Shared-mailbox email

Do not grant the managed identity Entra `Mail.Send`; that would allow sending as every mailbox. Instead, connect as an Exchange administrator and run:

```powershell
./scripts/Configure-ExchangeMail.ps1 -SenderMailbox notifications@contoso.com
azd provision
```

The script creates an Exchange service-principal pointer, a recipient scope matching the mailbox, and an `Application Mail.Send` management-role assignment. Verify the displayed `Test-ServicePrincipalAuthorization` result. Graph returning `202 Accepted` means Exchange accepted the message for processing, not that final delivery is guaranteed.

## Licensing

- An active Intune subscription is required; managed users/devices need licensing appropriate to their management scenario.
- Teams recipients need Teams service enabled. Teams Workflows webhook templates do not currently require premium Power Automate licensing, but Power Platform request limits apply.
- The sender must be a usable Exchange Online shared mailbox. Exchange licensing and size/feature requirements still apply to that mailbox.
- Entra Free retains audit logs for 7 days; P1/P2 retains them for 30 days. Export logs for longer retention.
