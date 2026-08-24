import type { DeviceEvent, ManagedDevice } from "../src/domain.js";
import type { DirectoryAudit } from "../src/normalization.js";

export const ids = {
  audit: "audit-1",
  device: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  managedDevice: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  actor: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  owner: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
};

export const registrationAudit: DirectoryAudit = {
  id: ids.audit,
  correlationId: "audit-correlation-1",
  activityDateTime: "2026-08-17T10:00:00.000Z",
  activityDisplayName: "Register device",
  result: "success",
  initiatedBy: { user: { id: ids.actor, displayName: "Help Desk", userPrincipalName: "helpdesk@example.com" } },
  targetResources: [
    { type: "User", id: ids.owner, displayName: "Device Owner", userPrincipalName: "owner@example.com" },
    { type: "Device", id: ids.device, displayName: "DESKTOP-01", modifiedProperties: [
      { displayName: "OwnerId", newValue: `"${ids.owner}"` },
      { displayName: "DeviceId", newValue: `"${ids.device}"` }
    ] }
  ]
};

export const managedDevice: ManagedDevice = {
  id: ids.managedDevice,
  azureADDeviceId: ids.device,
  deviceName: "DESKTOP-01",
  enrolledDateTime: "2026-08-17T09:30:00.000Z",
  complianceState: "compliant",
  operatingSystem: "Windows",
  managedDeviceOwnerType: "company",
  userId: ids.owner,
  userPrincipalName: "owner@example.com"
};

export const noncompliantEvent: DeviceEvent = {
  id: "event-1",
  type: "deviceNoncompliant",
  occurredAt: "2026-08-17T10:00:00.000Z",
  severity: "high",
  device: {
    id: ids.managedDevice,
    azureADDeviceId: ids.device,
    displayName: "DESKTOP-01",
    operatingSystem: "Windows",
    ownership: "company"
  },
  owner: { id: ids.owner, upn: "owner@example.com" },
  previousComplianceState: "compliant",
  complianceState: "noncompliant"
};
