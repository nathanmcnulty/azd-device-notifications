# Privacy and retention

The service stores only the fields needed to correlate and deliver lifecycle notifications: event IDs and times, device IDs/names, operating system and ownership, compliance state/deadline, actor or owner IDs/UPNs, routing fingerprints, Teams conversation references, and delivery timestamps. Raw Graph audit records and full Intune inventory are not persisted or written to application logs.

Device and identity data remains in the selected Azure region except for Microsoft Graph, Teams, Exchange Online, Azure Bot, and their normal service processing boundaries. Review organizational data-residency requirements before deployment.

Azure Table data uses the storage account lifecycle of the deployment. Application Insights and Log Analytics are configured for 30 days. Native Entra audit retention is 7 days for Free and 30 days for P1/P2 at the time of writing. Configure storage lifecycle or an operational purge process when notification state must have a shorter retention period.

Teams Workflow callback URLs are credentials. Restrict access to Function App configuration, assign Workflow co-owners, and rotate the URL if exposed. Shared-mailbox sent-item retention is not used by this implementation (`saveToSentItems` is false); notification history records metadata, not message bodies.

The service never takes destructive device action. Admin links are generated only from validated GUIDs and lead to Microsoft admin experiences where normal authorization still applies.
