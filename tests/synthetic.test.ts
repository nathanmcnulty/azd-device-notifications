import { describe, expect, it, vi } from "vitest";
import { PermanentDeliveryError, type DeliveryReservation, type NotificationHistoryRepository } from "../src/domain.js";
import { loadRoutingConfig } from "../src/routing.js";
import { runSyntheticDeliveryProof } from "../src/synthetic.js";

class ProofHistory implements NotificationHistoryRepository {
  private sequence = 0;
  async reserveDelivery(): Promise<DeliveryReservation> { return { status: "reserved", etag: String(++this.sequence) }; }
  async releaseDelivery() {}
  async completeDelivery() {}
}

const logger = { info() {}, warn() {}, error() {} };
const graph = { async *pages<T>() { yield [] as T[]; }, async post() {} };
const environment = {
  name: "test", tenantId: "11111111-1111-4111-8111-111111111111",
  subscriptionId: "22222222-2222-4222-8222-222222222222", resourceGroup: "rg-device-notifications-test"
};
const emptyEvents = {
  deviceRegistered: { user: [] as never[], admin: [] as never[] },
  deviceEnrolled: { user: [] as never[], admin: [] as never[] },
  deviceNoncompliant: { user: [] as never[], admin: [] as never[] }
};

describe("synthetic delivery proof", () => {
  it("refuses proof after collection is enabled without dispatching", async () => {
    const fetcher = vi.fn();
    const response = await runSyntheticDeliveryProof({
      eventType: "deviceRegistered",
      testUser: { id: "00000000-0000-0000-0000-000000000000", upn: "", email: "", displayName: "Device notification test user" }
    }, {
      graph, bot: { async sendToEntraUser() {} }, history: new ProofHistory(), logger,
      routing: loadRoutingConfig(JSON.stringify({ events: emptyEvents })), adminEmails: [], fetcher, environment
    }, true);
    expect(response).toMatchObject({ status: 409, jsonBody: { success: false, eventType: "deviceRegistered", status: "refused" } });
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("proves a selected route through the actual dispatcher", async () => {
    const fetcher = vi.fn(async (_input: string | URL | Request, _init?: RequestInit) => new Response(undefined, { status: 202 }));
    const routing = loadRoutingConfig(JSON.stringify({
      events: { ...emptyEvents, deviceRegistered: { user: [], admin: ["teamsWebhook"] } }
    }));
    const response = await runSyntheticDeliveryProof({
      eventType: "deviceRegistered",
      testUser: { id: "00000000-0000-0000-0000-000000000000", upn: "", email: "", displayName: "Device notification test user" }
    }, {
      graph, bot: { async sendToEntraUser() {} }, history: new ProofHistory(), logger, routing,
      adminEmails: [], webhookUrl: "https://example.invalid/workflow", fetcher, environment
    }, false, new Date("2026-08-22T12:00:00.000Z"));
    expect(response).toMatchObject({
      status: 200,
      jsonBody: {
        success: true,
        eventType: "deviceRegistered",
        summary: { selectedRoutes: 1, deliveredRoutes: 1, unavailableRoutes: 0,
          routes: [{ audience: "admin", transport: "teamsWebhook", status: "delivered" }] }
      }
    });
    const payload = JSON.parse(String(fetcher.mock.calls[0][1]?.body));
    const card = payload.attachments[0].content;
    expect(card.body[0].text).toBe("[TEST] Device registered");
    expect(card.actions).toEqual([]);
  });

  it("returns non-success when a selected Teams route is unavailable", async () => {
    const routing = loadRoutingConfig(JSON.stringify({
      events: { ...emptyEvents, deviceEnrolled: { user: ["teamsDm"], admin: [] } }
    }));
    const response = await runSyntheticDeliveryProof({
      eventType: "deviceEnrolled",
      testUser: { id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", upn: "owner@example.com", displayName: "Test Owner" }
    }, {
      graph,
      bot: { async sendToEntraUser() { throw new PermanentDeliveryError("No installation"); } },
      history: new ProofHistory(), logger, routing, adminEmails: [], environment
    }, false);
    expect(response).toMatchObject({
      status: 424,
      jsonBody: { success: false, eventType: "deviceEnrolled", summary: { unavailableRoutes: 1,
        routes: [{ audience: "user", transport: "teamsDm", status: "unavailable" }] } }
    });
  });

  it("applies monitored scope to proof events", async () => {
    const routing = loadRoutingConfig(JSON.stringify({
      events: { ...emptyEvents, deviceRegistered: { user: ["teamsDm"], admin: [] } },
      monitoredUserIds: ["ffffffff-ffff-4fff-8fff-ffffffffffff"]
    }));
    const response = await runSyntheticDeliveryProof({
      eventType: "deviceRegistered", testUser: { id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd" }
    }, {
      graph, bot: { async sendToEntraUser() {} }, history: new ProofHistory(), logger, routing, adminEmails: [], environment
    }, false);
    expect(response).toMatchObject({ status: 424, jsonBody: { success: false,
      summary: { selectedRoutes: 0, suppressedReason: "subject outside monitored scope" } } });
  });
});
