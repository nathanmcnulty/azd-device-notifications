import { describe, expect, it } from "vitest";
import type { DeviceEvent, Logger } from "../src/domain.js";
import {
  loadNotificationEnvironment,
  newNotificationDeliveryResult,
  normalizeDeviceNotification,
  notificationContractRoute,
  notificationIdempotencyKey,
  recordNotificationDeliveryResult
} from "../src/notification-contracts.js";
import type { DeliveryRoute } from "../src/routing.js";
import { noncompliantEvent } from "./fixtures.js";

const environment = {
  name: "test", tenantId: "11111111-1111-4111-8111-111111111111",
  subscriptionId: "22222222-2222-4222-8222-222222222222", resourceGroup: "rg-device-notifications-test"
};

function propertyNames(value: unknown): string[] {
  if (!value || typeof value !== "object") return [];
  return Object.entries(value).flatMap(([name, child]) => [name, ...propertyNames(child)]);
}

describe("notification contract adapter", () => {
  it.each([
    ["deviceRegistered", "entra.device.registered", "microsoftGraph.directoryAudit"],
    ["deviceEnrolled", "intune.device.enrolled", "microsoftGraph.deviceManagement"],
    ["deviceNoncompliant", "intune.device.complianceChanged", "microsoftGraph.deviceManagement"]
  ] as const)("maps %s to its namespaced event and Graph source", (type, eventType, source) => {
    const event: DeviceEvent = { ...noncompliantEvent, type };
    expect(normalizeDeviceNotification(event, environment)).toMatchObject({
      schemaVersion: "1.0", eventId: event.id, eventType, source, correlationId: event.id,
      isTest: false, environment
    });
  });

  it("preserves Graph correlation and synthetic state without logging envelope data", () => {
    const envelope = normalizeDeviceNotification({
      ...noncompliantEvent,
      correlationId: "graph-correlation-42",
      synthetic: true,
      owner: { ...noncompliantEvent.owner, email: "private-owner@example.test" }
    }, environment);
    expect(envelope.correlationId).toBe("graph-correlation-42");
    expect(envelope.isTest).toBe(true);
    expect(envelope.data).toMatchObject({ owner: { email: "private-owner@example.test" } });

    const messages: string[] = [];
    const logger: Logger = { info: (message) => messages.push(message), warn() {}, error() {} };
    const result = newNotificationDeliveryResult(envelope, notificationContractRoute({
      audience: "user", transport: "teamsDm", severity: "high"
    }), { status: "succeeded", attempt: 1, recordedAt: new Date("2026-08-23T12:00:00.000Z") });
    recordNotificationDeliveryResult(logger, result);

    expect(messages).toEqual([`AZD_NOTIFICATION_DELIVERY_RESULT ${JSON.stringify(result)}`]);
    expect(JSON.stringify(messages)).not.toContain("private-owner@example.test");
    expect(propertyNames(result)).not.toContain("data");
  });

  it.each([
    [{ audience: "user", transport: "teamsDm", severity: "low" }, "user-teams-dm", "teams.bot"],
    [{ audience: "admin", transport: "teamsWebhook", severity: "low" }, "admin-teams-workflow", "teams.workflowWebhook"],
    [{ audience: "user", transport: "email", severity: "low" }, "user-email", "email.graph"],
    [{ audience: "admin", transport: "email", severity: "low" }, "admin-email", "email.graph"]
  ] as Array<[DeliveryRoute, string, string]>)("maps a solution route to %s", (route, id, transport) => {
    expect(notificationContractRoute(route)).toEqual({ id, audience: route.audience, transport });
  });

  it("matches the canonical lowercase SHA-256 idempotency vector", () => {
    expect(notificationIdempotencyKey(
      environment.tenantId, "intune.device.complianceChanged", "event-1", "user-teams-dm"
    )).toBe("59230737f7937c0739fd937fa158616b9bf665d52b5483136d557b52a1df50b9");
  });

  it("loads only bounded environment metadata and rejects incomplete configuration", () => {
    expect(loadNotificationEnvironment({
      AZURE_ENV_NAME: "dev", AZURE_TENANT_ID: environment.tenantId,
      AZURE_SUBSCRIPTION_ID: environment.subscriptionId, AZURE_RESOURCE_GROUP: "rg-dev",
      TEAMS_ADMIN_WEBHOOK_URL: "https://example.test?sig=sensitive",
      ACCESS_TOKEN: "sensitive-token"
    })).toEqual({ ...environment, name: "dev", resourceGroup: "rg-dev" });
    expect(() => loadNotificationEnvironment({
      AZURE_ENV_NAME: "dev", AZURE_TENANT_ID: environment.tenantId,
      AZURE_SUBSCRIPTION_ID: environment.subscriptionId
    })).toThrow("AZURE_RESOURCE_GROUP");
  });

  it("keeps every delivery-result state free of destinations, recipients, payloads, cards, and raw errors", () => {
    const envelope = normalizeDeviceNotification({
      ...noncompliantEvent,
      owner: { ...noncompliantEvent.owner, email: "private-owner@example.test" }
    }, environment);
    const route = notificationContractRoute({ audience: "admin", transport: "teamsWebhook", severity: "high" });
    const recordedAt = new Date("2026-08-23T12:00:00.000Z");
    const results = [
      newNotificationDeliveryResult(envelope, route, { status: "succeeded", attempt: 1, recordedAt }),
      newNotificationDeliveryResult(envelope, route, { status: "alreadyDelivered", attempt: 0, recordedAt }),
      newNotificationDeliveryResult(envelope, route, { status: "skipped", attempt: 0, recordedAt, skipReason: "concurrentDelivery" }),
      newNotificationDeliveryResult(envelope, route, {
        status: "failed", attempt: 1, recordedAt,
        failure: { category: "transientProvider", retryable: true, code: "TransientDeliveryFailure" }
      })
    ];
    const forbidden = [
      "data", "destination", "recipient", "card", "payload", "body", "webhook", "webhookUrl",
      "token", "authorization", "rawError", "email", "userPrincipalName"
    ];
    for (const result of results) {
      expect(forbidden.some((name) => propertyNames(result).includes(name))).toBe(false);
      expect(JSON.stringify(result)).not.toMatch(/private-owner|example\.test|sensitive-|Bearer |[?&]sig=/i);
    }
  });
});
