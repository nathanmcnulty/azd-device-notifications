import { createHash } from "node:crypto";
import type { DeviceEvent } from "./domain.js";

interface AuditResource {
  id?: string;
  displayName?: string;
  type?: string;
  userPrincipalName?: string;
  modifiedProperties?: Array<{ displayName?: string; newValue?: string }>;
}

export interface DirectoryAudit {
  id?: string;
  activityDateTime?: string;
  activityDisplayName?: string;
  category?: string;
  result?: string;
  initiatedBy?: {
    user?: { id?: string; displayName?: string; userPrincipalName?: string };
    app?: { appId?: string; displayName?: string };
  };
  targetResources?: AuditResource[];
}

const cleanJsonString = (value?: string): string | undefined => {
  if (!value) return undefined;
  try {
    const parsed: unknown = JSON.parse(value);
    return typeof parsed === "string" ? parsed : undefined;
  } catch {
    return value.replace(/^"|"$/g, "");
  }
};

function property(resource: AuditResource | undefined, names: string[]): string | undefined {
  const found = resource?.modifiedProperties?.find((item) =>
    names.some((name) => item.displayName?.toLowerCase() === name.toLowerCase())
  );
  return cleanJsonString(found?.newValue);
}

export function normalizeRegistration(audit: DirectoryAudit): DeviceEvent | undefined {
  const activity = audit.activityDisplayName?.trim().toLowerCase();
  if (audit.result?.toLowerCase() !== "success" || !activity || !/^(register|add) device$/.test(activity)) return undefined;

  const resources = audit.targetResources ?? [];
  const device = resources.find((resource) => resource.type?.toLowerCase() === "device") ??
    resources.find((resource) => property(resource, ["DeviceId", "AzureADDeviceId"]));
  if (!device) return undefined;
  const ownerResource = resources.find((resource) => resource.type?.toLowerCase() === "user");
  const actor = audit.initiatedBy?.user;
  const occurredAt = audit.activityDateTime;
  if (!occurredAt) return undefined;

  const azureADDeviceId = property(device, ["DeviceId", "AzureADDeviceId"]) ?? device.id;
  const ownerId = property(device, ["OwnerId", "UserId"]) ?? ownerResource?.id;
  const identity = audit.id ?? `${occurredAt}:${azureADDeviceId ?? device.displayName ?? "device"}`;
  return {
    id: createHash("sha256").update(`registration:${identity}`).digest("hex"),
    type: "deviceRegistered",
    occurredAt,
    severity: "low",
    device: { id: device.id, azureADDeviceId, displayName: device.displayName },
    actor: actor ? { id: actor.id, displayName: actor.displayName, upn: actor.userPrincipalName } : undefined,
    owner: ownerId || ownerResource
      ? { id: ownerId, displayName: ownerResource?.displayName, upn: ownerResource?.userPrincipalName }
      : actor ? { id: actor.id, displayName: actor.displayName, upn: actor.userPrincipalName } : undefined
  };
}

export function isValidGuid(value: string | undefined): value is string {
  return !!value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export function adminLinks(event: DeviceEvent): { entra?: string; intune?: string } {
  const entra = isValidGuid(event.device.azureADDeviceId)
    ? `https://entra.microsoft.com/#view/Microsoft_AAD_Devices/DeviceDetailsMenuBlade/~/Overview/deviceId/${encodeURIComponent(event.device.azureADDeviceId)}`
    : undefined;
  const intune = isValidGuid(event.device.id)
    ? `https://intune.microsoft.com/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/~/overview/mdmDeviceId/${encodeURIComponent(event.device.id)}`
    : undefined;
  return { entra, intune };
}
