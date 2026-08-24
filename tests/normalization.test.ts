import { describe, expect, it } from "vitest";
import { adminLinks, normalizeRegistration } from "../src/normalization.js";
import { ids, registrationAudit } from "./fixtures.js";

describe("directory audit normalization", () => {
  it("recognizes registration with reordered resources and preserves actor and owner", () => {
    const event = normalizeRegistration({ ...registrationAudit, targetResources: [...registrationAudit.targetResources!].reverse() });
    expect(event).toMatchObject({
      type: "deviceRegistered",
      correlationId: "audit-correlation-1",
      device: { azureADDeviceId: ids.device },
      actor: { id: ids.actor },
      owner: { id: ids.owner }
    });
    expect(event?.actor?.id).not.toBe(event?.owner?.id);
  });

  it("tolerates empty target resources and ignores failed or unrelated records", () => {
    expect(normalizeRegistration({ ...registrationAudit, targetResources: [] })).toBeUndefined();
    expect(normalizeRegistration({ ...registrationAudit, result: "failure" })).toBeUndefined();
    expect(normalizeRegistration({ ...registrationAudit, activityDisplayName: "Delete device" })).toBeUndefined();
  });

  it("uses the registering user when the audit has no explicit owner", () => {
    const device = registrationAudit.targetResources![1];
    const event = normalizeRegistration({
      ...registrationAudit,
      targetResources: [{
        ...device,
        modifiedProperties: device.modifiedProperties?.filter((property) => property.displayName !== "OwnerId")
      }]
    });
    expect(event?.actor?.id).toBe(ids.actor);
    expect(event?.owner?.id).toBe(ids.actor);
  });

  it("creates admin links only from validated GUIDs", () => {
    const event = normalizeRegistration(registrationAudit)!;
    expect(adminLinks(event).entra).toContain(ids.device);
    expect(adminLinks({ ...event, device: { id: "../../bad", azureADDeviceId: "javascript:alert(1)" } })).toEqual({ entra: undefined, intune: undefined });
  });
});
