import { describe, expect, it, vi } from "vitest";
import { dispatchEvent, shapeAdaptiveCard, validateDeliveryConfiguration } from "../src/delivery.js";
import type { DeliveryReservation, Logger, NotificationHistoryRepository } from "../src/domain.js";
import { loadRoutingConfig } from "../src/routing.js";
import { noncompliantEvent } from "./fixtures.js";

class MemoryHistory implements NotificationHistoryRepository {
  private readonly states = new Map<string, { status: "pending" | "delivered"; etag: string }>();
  private sequence = 0;
  async reserveDelivery(key: string): Promise<DeliveryReservation> {
    const existing = this.states.get(key);
    if (existing) return { status: existing.status };
    const etag = String(++this.sequence);
    this.states.set(key, { status: "pending", etag });
    return { status: "reserved", etag };
  }
  async releaseDelivery(key: string, etag: string) {
    if (this.states.get(key)?.etag === etag) this.states.delete(key);
  }
  async completeDelivery(key: string, etag: string) {
    if (this.states.get(key)?.etag !== etag) throw new Error("reservation changed");
    this.states.set(key, { status: "delivered", etag });
  }
}

const logger: Logger = { info() {}, warn() {}, error() {} };

describe("delivery shaping", () => {
  it("shapes owner bot delivery without Graph chat sends", async () => {
    const sendToEntraUser = vi.fn(async () => undefined);
    const post = vi.fn(async () => undefined);
    const history = new MemoryHistory();
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } }
    }));
    const dependencies = {
      graph: { async *pages<T>() { yield [] as T[]; }, post },
      bot: { sendToEntraUser }, history, logger, routing, adminEmails: []
    };
    await dispatchEvent(noncompliantEvent, dependencies);
    await dispatchEvent(noncompliantEvent, dependencies);
    expect(sendToEntraUser).toHaveBeenCalledTimes(1);
    expect(sendToEntraUser).toHaveBeenCalledWith(noncompliantEvent.owner?.id, expect.objectContaining({ type: "AdaptiveCard" }));
    expect(post).not.toHaveBeenCalled();
  });

  it("does not put unsafe identifiers into card actions", () => {
    const card = shapeAdaptiveCard({ ...noncompliantEvent, device: { id: "bad", azureADDeviceId: "bad" } }, "admin");
    expect(card).toMatchObject({ actions: [] });
  });

  it("attempts admin fan-out when a user route fails", async () => {
    const fetcher = vi.fn(async () => new Response(undefined, { status: 202 }));
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: ["teamsDm"], admin: ["teamsWebhook"] } }
    }));
    await expect(dispatchEvent(noncompliantEvent, {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { async sendToEntraUser() { throw new Error("No conversation"); } },
      history: new MemoryHistory(),
      logger,
      routing,
      adminEmails: [],
      webhookUrl: "https://example.invalid/workflow",
      fetcher
    })).rejects.toThrow("1 notification route(s) failed");
    expect(fetcher).toHaveBeenCalledOnce();
  });

  it("enforces configured monitored group membership", async () => {
    const sendToEntraUser = vi.fn(async () => undefined);
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } },
      monitoredGroupIds: ["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"]
    }));
    await dispatchEvent(noncompliantEvent, {
      graph: {
        async *pages<T>() { yield [] as T[]; }, async post() {},
        async checkUserMemberGroups() { return []; }
      },
      bot: { sendToEntraUser },
      history: new MemoryHistory(),
      logger,
      routing,
      adminEmails: []
    });
    expect(sendToEntraUser).not.toHaveBeenCalled();
  });

  it("uses union semantics when both monitored users and groups are configured", async () => {
    const groupId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    const otherUser = "ffffffff-ffff-4fff-8fff-ffffffffffff";
    const sendToEntraUser = vi.fn(async () => undefined);
    const makeDependencies = (memberships: string[]) => ({
      graph: {
        async *pages<T>() { yield [] as T[]; }, async post() {},
        async checkUserMemberGroups() { return memberships; }
      },
      bot: { sendToEntraUser }, history: new MemoryHistory(), logger, adminEmails: [],
      routing: loadRoutingConfig(JSON.stringify({
        events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } },
        monitoredUserIds: [otherUser], monitoredGroupIds: [groupId]
      }))
    });

    await dispatchEvent(noncompliantEvent, makeDependencies([groupId]));
    await dispatchEvent({ ...noncompliantEvent, id: "direct", owner: { ...noncompliantEvent.owner, id: otherUser } }, makeDependencies([]));
    await dispatchEvent({ ...noncompliantEvent, id: "neither" }, makeDependencies([]));
    await dispatchEvent({ ...noncompliantEvent, id: "missing", owner: undefined, actor: undefined }, makeDependencies([groupId]));
    expect(sendToEntraUser).toHaveBeenCalledTimes(2);
  });

  it("does not send a route concurrently while its reservation is pending", async () => {
    let releaseSend!: () => void;
    const blocked = new Promise<void>((resolve) => { releaseSend = resolve; });
    const sendToEntraUser = vi.fn(async () => blocked);
    const history = new MemoryHistory();
    const routing = loadRoutingConfig(JSON.stringify({ events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } } }));
    const dependencies = {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { sendToEntraUser }, history, logger, routing, adminEmails: []
    };
    const first = dispatchEvent(noncompliantEvent, dependencies);
    await vi.waitFor(() => expect(sendToEntraUser).toHaveBeenCalledOnce());
    await expect(dispatchEvent(noncompliantEvent, dependencies)).rejects.toThrow("1 notification route(s) failed");
    releaseSend();
    await first;
    await dispatchEvent(noncompliantEvent, dependencies);
    expect(sendToEntraUser).toHaveBeenCalledOnce();
  });

  it("releases a failed route so a queue retry can deliver it", async () => {
    const sendToEntraUser = vi.fn()
      .mockRejectedValueOnce(new Error("temporary"))
      .mockResolvedValueOnce(undefined);
    const dependencies = {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} }, bot: { sendToEntraUser },
      history: new MemoryHistory(), logger, adminEmails: [],
      routing: loadRoutingConfig(JSON.stringify({ events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } } }))
    };
    await expect(dispatchEvent(noncompliantEvent, dependencies)).rejects.toThrow("1 notification route(s) failed");
    await dispatchEvent(noncompliantEvent, dependencies);
    expect(sendToEntraUser).toHaveBeenCalledTimes(2);
  });

  it("rejects enabled routes whose required destinations are missing", () => {
    const disabled = loadRoutingConfig(JSON.stringify({
      events: { deviceRegistered: { user: [], admin: [] }, deviceEnrolled: { user: [], admin: [] }, deviceNoncompliant: { user: [], admin: [] } }
    }));
    expect(() => validateDeliveryConfiguration(disabled, { adminEmails: [] })).toThrow("At least one");

    const webhook = loadRoutingConfig(JSON.stringify({
      events: { deviceRegistered: { user: [], admin: ["teamsWebhook"] }, deviceEnrolled: { user: [], admin: [] }, deviceNoncompliant: { user: [], admin: [] } }
    }));
    expect(() => validateDeliveryConfiguration(webhook, { adminEmails: [] })).toThrow("TEAMS_ADMIN_WEBHOOK_URL");

    const email = loadRoutingConfig(JSON.stringify({
      events: { deviceRegistered: { user: [], admin: [] }, deviceEnrolled: { user: [], admin: [] }, deviceNoncompliant: { user: ["email"], admin: ["email"] } }
    }));
    expect(() => validateDeliveryConfiguration(email, { adminEmails: [] })).toThrow("EMAIL_SENDER_UPN");
    expect(() => validateDeliveryConfiguration(email, { adminEmails: [], emailSenderUpn: "sender@example.com" })).toThrow("ADMIN_EMAIL_RECIPIENTS");
    expect(() => validateDeliveryConfiguration(email, { adminEmails: ["not-an-address"], emailSenderUpn: "sender@example.com" })).toThrow("valid addresses");
    expect(() => validateDeliveryConfiguration(email, { adminEmails: ["admin@example.com"], emailSenderUpn: "not-an-address" })).toThrow("EMAIL_SENDER_UPN must be a valid address");
    expect(() => validateDeliveryConfiguration(email, { adminEmails: ["admin@example.com"], emailSenderUpn: "sender@example.com" })).not.toThrow();
    expect(() => validateDeliveryConfiguration(webhook, { adminEmails: [], webhookUrl: "http://example.com" })).toThrow("valid HTTPS URL");
  });
});
