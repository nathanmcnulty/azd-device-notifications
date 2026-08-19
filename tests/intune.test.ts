import { describe, expect, it } from "vitest";
import { detectManagedDeviceEvents } from "../src/intune.js";
import { managedDevice } from "./fixtures.js";

const now = new Date("2026-08-17T10:00:00.000Z");

describe("Intune snapshot detection", () => {
  it("emits a recent newly seen enrollment", () => {
    const result = detectManagedDeviceEvents(managedDevice, undefined, now, 24 * 3_600_000);
    expect(result.events).toHaveLength(1);
    expect(result.events[0]).toMatchObject({ type: "deviceEnrolled", owner: { upn: "owner@example.com" } });
  });

  it("establishes an old initial baseline without flooding enrollment or compliance", () => {
    const result = detectManagedDeviceEvents({
      ...managedDevice, enrolledDateTime: "2025-01-01T00:00:00.000Z", complianceState: "noncompliant"
    }, undefined, now, 24 * 3_600_000);
    expect(result.events).toEqual([]);
    expect(result.snapshot.complianceState).toBe("noncompliant");
  });

  it("emits a compliance transition and preserves the grace deadline", () => {
    const baseline = detectManagedDeviceEvents(managedDevice, undefined, now, 0).snapshot;
    const result = detectManagedDeviceEvents({
      ...managedDevice,
      complianceState: "inGracePeriod",
      complianceGracePeriodExpirationDateTime: "2026-08-18T10:00:00.000Z"
    }, baseline, new Date("2026-08-17T10:05:00.000Z"), 0);
    expect(result.events[0]).toMatchObject({
      type: "deviceNoncompliant",
      previousComplianceState: "compliant",
      complianceState: "inGracePeriod",
      gracePeriodExpirationDateTime: "2026-08-18T10:00:00.000Z"
    });
  });

  it("preserves unknown compliance distinctly", () => {
    const previous = detectManagedDeviceEvents(managedDevice, undefined, now, 0).snapshot;
    const result = detectManagedDeviceEvents({ ...managedDevice, complianceState: undefined }, previous, now, 0);
    expect(result.snapshot.complianceState).toBe("unknown");
    expect(result.events[0]).toMatchObject({ complianceState: "unknown", previousComplianceState: "compliant" });
  });

  it("does not classify unrelated management states as compliance failures", () => {
    const previous = detectManagedDeviceEvents(managedDevice, undefined, now, 0).snapshot;
    const result = detectManagedDeviceEvents({ ...managedDevice, complianceState: "configManager" }, previous, now, 0);
    expect(result.events).toEqual([]);
    expect(result.snapshot.complianceState).toBe("configManager");
  });
});
