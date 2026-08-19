# azd-device-notifications

Azure Developer CLI template for actionable Microsoft Entra and Intune device lifecycle notifications. The initial release detects:

- New Microsoft Entra device registrations.
- New Intune managed-device enrollments.
- Intune compliance transitions from one state to a noncompliant, error, grace-period, or unknown state.

Each event can independently fan out to the device owner, administrators, or both. Supported delivery routes are Teams personal messages, Teams channel/chat Workflows webhooks, and email from an Exchange Online shared mailbox.

## Architecture

An Azure Functions Flex Consumption app polls supported Microsoft Graph v1.0 endpoints. Azure Tables store overlapping poll watermarks, device snapshots, event fingerprints, Teams conversation references, and delivery history. Azure Queue Storage separates detection from retryable delivery.

```text
Entra directory audits ----+
                            +--> normalize/correlate --> Tables --> Queue --> Teams bot DM
Intune managed devices ----+                                  |--> Teams Workflow
                                                               +--> Exchange shared mailbox
```

Polling is deliberate: Microsoft Graph does not currently offer change notifications for `directoryAudit`, Entra `device`, or Intune `managedDevice`. Entra and Intune diagnostic streaming can later reduce latency, but polling remains the reconciliation path.

See [architecture and boundaries](docs/architecture.md).

## Deploy

1. Install Azure CLI, Azure Developer CLI 1.23 or later, PowerShell 7, and Node.js 22.
2. Create an environment with `azd env new` and select the intended subscription and tenant.
3. Configure routing as described in [configuration](docs/configuration.md).
4. Run `azd up`.
5. Upload `teams-app/device-notifications.zip` in the Teams admin center and install it for users who should receive personal notifications.
6. If using email, run `./scripts/Configure-ExchangeMail.ps1 -SenderMailbox notifications@contoso.com`, then run `azd provision`.

Full prerequisites, permissions, Teams Workflow setup, and validation steps are in [deployment](docs/deployment.md).

## Defaults

| Event | End user | Admin |
|---|---|---|
| Device registered | Teams DM | Teams Workflow |
| Device enrolled | Teams DM | Teams Workflow |
| Device noncompliant | Teams DM and email | Teams Workflow and email |

No device disable, delete, retire, wipe, compliance write, certificate revocation, or other destructive action is implemented.

## Test

```powershell
cd src
npm ci
npm test
npm run typecheck
npm run build
cd ..
az bicep build --file infra/main.bicep
```

Fixtures cover registration, delayed audit records, enrollment, first-run baseline suppression, compliance transitions, unknown compliance, duplicate events, and missing owners.

## Documentation

- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)
- [Deployment and permissions](docs/deployment.md)
- [Operations and validation](docs/operations.md)
- [Privacy and retention](docs/privacy.md)
