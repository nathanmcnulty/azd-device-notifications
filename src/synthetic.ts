import { randomUUID } from "node:crypto";
import type { DeviceEvent, EventType } from "./domain.js";
import { DeliveryDispatchError, dispatchEvent, type DeliveryDependencies } from "./delivery.js";
import { isValidGuid } from "./normalization.js";

const eventTypes = new Set<EventType>(["deviceRegistered", "deviceEnrolled", "deviceNoncompliant"]);
const emailPattern = /^[^@\s]+@[^@\s]+$/;
const emptyGuid = "00000000-0000-0000-0000-000000000000";

export interface SyntheticDeliveryInput {
  eventType?: unknown;
  testUser?: unknown;
}

export interface SyntheticDeliveryResponse {
  status: number;
  jsonBody: Record<string, unknown>;
}

function optionalString(value: unknown, name: string, validator: (candidate: string) => boolean): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || !validator(value)) throw new Error(`${name} is invalid`);
  return value;
}

export async function runSyntheticDeliveryProof(
  input: SyntheticDeliveryInput,
  dependencies: DeliveryDependencies,
  collectionEnabled: boolean,
  now = new Date()
): Promise<SyntheticDeliveryResponse> {
  if (collectionEnabled) {
    return { status: 409, jsonBody: { success: false, eventType: input.eventType, status: "refused", message: "Synthetic delivery proof is available only before collection is enabled." } };
  }
  if (typeof input.eventType !== "string" || !eventTypes.has(input.eventType as EventType)) {
    return { status: 400, jsonBody: { success: false, eventType: input.eventType, status: "invalid", message: "eventType must be deviceRegistered, deviceEnrolled, or deviceNoncompliant." } };
  }

  let userId: string | undefined;
  let upn: string | undefined;
  let email: string | undefined;
  let displayName: string | undefined;
  try {
    if (input.testUser !== undefined && (typeof input.testUser !== "object" || input.testUser === null || Array.isArray(input.testUser))) {
      throw new Error("testUser is invalid");
    }
    const testUser = (input.testUser ?? {}) as Record<string, unknown>;
    userId = optionalString(testUser.id, "testUser.id", (value) => value === emptyGuid || isValidGuid(value));
    if (userId === emptyGuid) userId = undefined;
    upn = optionalString(testUser.upn, "testUser.upn", (value) => value.length <= 320 && emailPattern.test(value));
    email = optionalString(testUser.email, "testUser.email", (value) => value.length <= 320 && emailPattern.test(value));
    displayName = optionalString(testUser.displayName, "testUser.displayName", (value) => value.trim().length > 0 && value.length <= 200);
  } catch (error) {
    return { status: 400, jsonBody: { success: false, eventType: input.eventType, status: "invalid", message: error instanceof Error ? error.message : "Test user values are invalid." } };
  }

  const owner = userId || upn || email ? { id: userId, upn, email, displayName: displayName ?? "Synthetic test recipient" } : undefined;
  const event: DeviceEvent = {
    id: `synthetic-${randomUUID()}`,
    type: input.eventType as EventType,
    occurredAt: now.toISOString(),
    severity: input.eventType === "deviceNoncompliant" ? "high" : "low",
    synthetic: true,
    device: { displayName: "TEST ONLY - synthetic device notification" },
    owner,
    actor: owner,
    ...(input.eventType === "deviceNoncompliant"
      ? { previousComplianceState: "compliant", complianceState: "noncompliant" }
      : {})
  };

  try {
    const summary = await dispatchEvent(event, { ...dependencies, now });
    const completedRoutes = summary.deliveredRoutes + summary.alreadyDeliveredRoutes;
    if (summary.suppressedReason || summary.selectedRoutes === 0 || summary.unavailableRoutes > 0 || completedRoutes !== summary.selectedRoutes) {
      return {
        status: 424,
        jsonBody: { success: false, eventType: input.eventType, status: "incomplete", message: "One or more selected delivery routes were unavailable or suppressed.", summary }
      };
    }
    return { status: 200, jsonBody: { success: true, eventType: input.eventType, status: "succeeded", summary } };
  } catch (error) {
    const summary = error instanceof DeliveryDispatchError ? error.summary : undefined;
    return {
      status: 502,
      jsonBody: {
        success: false, eventType: input.eventType, status: "failed",
        message: "Synthetic delivery failed. Review Function logs for the affected route.",
        ...(summary ? { summary } : {})
      }
    };
  }
}
