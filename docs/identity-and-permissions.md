# Identity and permissions

This solution separates the deploying administrator from the runtime managed identity. Azure resource permissions do not grant Microsoft Graph or Exchange authority, and a directory role does not grant Azure subscription access.

## Human administrator roles

| Phase | Typical role | Purpose | Needed after setup? |
|---|---|---|---|
| Azure deployment | Owner, or Contributor plus User Access Administrator | Creates resources and Azure role assignments | Only for later Azure changes or teardown |
| Graph application-role assignment | Privileged Role Administrator | Assigns application permissions to the managed identity | Only when reconciling runtime permissions |
| Teams custom app | Teams Administrator | Uploads/approves the app and manages permission or setup policy | For app lifecycle and wider rollout |
| Teams Workflow | Workflow owner with destination access | Creates the callback, connection, co-ownership, and destination | Yes; the Workflow needs durable ownership |
| Exchange setup | Exchange Administrator | Creates/adopts mailbox-scoped Application RBAC objects | For mail changes and teardown |
| Test-device operation | Appropriate Intune/Entra administrator | Creates approved registration, enrollment, or compliance test conditions | Only for end-to-end drills |

Use least privilege and activate privileged roles only for the required phase. A single person may hold several roles, but the permission boundaries remain separate.

## Authentication behavior

The hooks reuse existing azd and Azure CLI caches. When no suitable cached token exists, authenticate with the normal operating-system broker or browser:

```powershell
azd auth login
az login --tenant <tenant-id>
```

Never add device-code switches. If normal broker/browser authentication cannot complete, stop and correct that blocker.

The preprovision guard compares:

- `AZURE_TENANT_ID` selected by azd;
- the tenant that owns `AZURE_SUBSCRIPTION_ID`; and
- the active Azure CLI tenant.

Deployment stops before Graph mutation when they differ.

## Runtime Microsoft Graph permissions

The user-assigned managed identity receives these application permissions:

| Permission | When | Purpose |
|---|---|---|
| `AuditLog.Read.All` | Always | Reads Entra directory audit events used for device-registration detection |
| `DeviceManagementManagedDevices.Read.All` | Always | Reads Intune managed-device state used for enrollment and compliance detection |
| `User.ReadBasic.All` | Only when monitored groups are configured | Resolves the user subject used for group-scoped filtering |
| `GroupMember.Read.All` | Only when monitored groups are configured | Tests transitive membership against configured group IDs |

The deployment removes the two optional group permissions when group filtering is no longer configured. Hidden-membership groups additionally require `Member.Read.Hidden`; the template does not grant it and therefore should not be configured with those groups.

The solution does not grant `Directory.Read.All`, Intune write permissions, `Teamwork.Migrate.All`, or an Entra `Mail.Send` application role. It does not use delegated end-user tokens at runtime.

## Azure permissions for the managed identity

Within the deployed resource group, the identity receives only the data-plane and monitoring roles needed by the Function App: access to its deployment package, notification queue, state tables, and Application Insights telemetry. Review `infra/resources.bicep` before adapting the identity for other workloads.

Deleting the user-assigned identity with the Azure deployment removes its managed-identity service principal. It does not prove removal of separately created Teams, Workflow, or Exchange configuration.

## Teams trust boundary

Teams personal messages use the Azure Bot endpoint and a conversation reference created by an installation activity. The workload cannot proactively message a user until the app is installed for that user. App approval and setup policies remain administrator-owned; the workload is not granted permission to install itself tenant-wide.

Administrator Teams delivery uses a Power Automate Workflows callback URL. The Workflow connection acts with its owner's connection and destination access. Use a durable organizational owner, add a co-owner, periodically test the Workflow, and rotate the callback when ownership changes or the value is exposed.

## Exchange trust boundary

Email uses Exchange Online Application RBAC rather than tenant-wide Entra `Mail.Send`. The configured management scope must resolve exclusively to the selected shared mailbox, and `Test-ServicePrincipalAuthorization` must report the identity in scope for that mailbox.

The configuration process records whether the Exchange service-principal pointer, scope, and role assignment were created by this azd environment or adopted. Teardown may remove only exact objects whose ownership is recorded as `created`; adopted objects require an explicit administrator decision.

## Permission review checklist

Before production enablement:

1. Confirm the managed identity has the two core Graph permissions and only the optional permissions required by group filtering.
2. Confirm no Entra `Mail.Send` role is assigned to the managed identity.
3. Confirm Exchange authorization includes only the intended sender mailbox.
4. Confirm the Teams app and Workflow use durable administrative ownership.
5. Confirm each route has passed an actual harmless delivery test.
6. Record the test date, administrators, selected scope, and remediation for any failed route.
