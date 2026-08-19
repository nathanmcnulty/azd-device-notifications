import { createHash } from "node:crypto";
import type { DeviceEvent, DeviceSnapshot, ManagedDevice } from "./domain.js";

const state = (value?: string) => value?.trim() || "unknown";
const alertingStates = new Set(["noncompliant", "error", "ingraceperiod", "unknown"]);

function eventId(kind: string, device: ManagedDevice, suffix: string): string {
  return createHash("sha256").update(`${kind}:${device.id}:${suffix}`).digest("hex");
}

function base(device: ManagedDevice) {
  return {
    id: device.id,
    azureADDeviceId: device.azureADDeviceId,
    displayName: device.deviceName,
    operatingSystem: device.operatingSystem,
    ownership: device.managedDeviceOwnerType
  };
}

export function detectManagedDeviceEvents(
  device: ManagedDevice,
  previous: DeviceSnapshot | undefined,
  now: Date,
  enrollmentLookbackMs: number
): { events: DeviceEvent[]; snapshot: DeviceSnapshot } {
  const complianceState = state(device.complianceState);
  const snapshot: DeviceSnapshot = {
    deviceId: device.id,
    firstSeenAt: previous?.firstSeenAt ?? now.toISOString(),
    enrolledDateTime: device.enrolledDateTime,
    complianceState,
    complianceGracePeriodExpirationDateTime: device.complianceGracePeriodExpirationDateTime,
    lastSyncDateTime: device.lastSyncDateTime
  };
  const events: DeviceEvent[] = [];
  const owner = device.userId || device.userPrincipalName || device.emailAddress
    ? { id: device.userId, displayName: device.userDisplayName, upn: device.userPrincipalName, email: device.emailAddress }
    : undefined;

  if (!previous && device.enrolledDateTime) {
    const enrolledAt = new Date(device.enrolledDateTime);
    if (!Number.isNaN(enrolledAt.valueOf()) && now.valueOf() - enrolledAt.valueOf() <= enrollmentLookbackMs) {
      events.push({
        id: eventId("enrollment", device, device.enrolledDateTime),
        type: "deviceEnrolled",
        occurredAt: enrolledAt.toISOString(),
        severity: "low",
        device: base(device),
        owner
      });
    }
  }

  if (previous && previous.complianceState !== complianceState && alertingStates.has(complianceState.toLowerCase())) {
    events.push({
      id: eventId("compliance", device, `${previous.complianceState}:${complianceState}:${device.lastSyncDateTime ?? device.complianceGracePeriodExpirationDateTime ?? now.toISOString()}`),
      type: "deviceNoncompliant",
      occurredAt: now.toISOString(),
      severity: complianceState === "noncompliant" || complianceState === "error" ? "high" : "medium",
      device: base(device),
      owner,
      previousComplianceState: previous.complianceState,
      complianceState,
      gracePeriodExpirationDateTime: device.complianceGracePeriodExpirationDateTime
    });
  }
  return { events, snapshot };
}
