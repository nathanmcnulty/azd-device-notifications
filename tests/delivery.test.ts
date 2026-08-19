import { describe, expect, it, vi } from "vitest";
import { dispatchEvent, shapeAdaptiveCard } from "../src/delivery.js";
import type { Logger, NotificationHistoryRepository } from "../src/domain.js";
import { loadRoutingConfig } from "../src/routing.js";
import { noncompliantEvent } from "./fixtures.js";

describe("delivery shaping", () => {
  it("shapes owner bot delivery without Graph chat sends", async () => {
    const sendToEntraUser = vi.fn(async () => undefined);
    const post = vi.fn(async () => undefined);
    const sent = new Set<string>();
    const history: NotificationHistoryRepository = {
      async has(key) { return sent.has(key); }, async record(key) { sent.add(key); }
    };
    const logger: Logger = { info() {}, warn() {}, error() {} };
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
      history: { async has() { return false; }, async record() {} },
      logger: { info() {}, warn() {}, error() {} },
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
      history: { async has() { return false; }, async record() {} },
      logger: { info() {}, warn() {}, error() {} },
      routing,
      adminEmails: []
    });
    expect(sendToEntraUser).not.toHaveBeenCalled();
  });
});
