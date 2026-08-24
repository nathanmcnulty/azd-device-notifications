import { describe, expect, it, vi } from "vitest";
import { dispatchEvent, shapeAdaptiveCard, validateDeliveryConfiguration } from "../src/delivery.js";
import {
  PermanentDeliveryError, ProviderRequestError,
  type DeliveryReservation, type Logger, type NotificationHistoryRepository
} from "../src/domain.js";
import {
  legacyDeliveryKey, normalizeDeviceNotification, notificationContractRoute, notificationIdempotencyKey,
  type NotificationDeliveryResult
} from "../src/notification-contracts.js";
import { loadRoutingConfig } from "../src/routing.js";
import { noncompliantEvent } from "./fixtures.js";

class MemoryHistory implements NotificationHistoryRepository {
  private readonly states = new Map<string, { status: "pending" | "delivered"; etag: string }>();
  readonly reservations: Array<{ key: string; legacyDeliveredKey?: string }> = [];
  private sequence = 0;
  async reserveDelivery(key: string, legacyDeliveredKey?: string): Promise<DeliveryReservation> {
    this.reservations.push({ key, legacyDeliveredKey });
    const legacy = legacyDeliveredKey ? this.states.get(legacyDeliveredKey) : undefined;
    if (legacy) return { status: legacy.status };
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
  seedDelivered(key: string) { this.states.set(key, { status: "delivered", etag: "legacy" }); }
  seedPending(key: string) { this.states.set(key, { status: "pending", etag: "legacy" }); }
  hasState(key: string) { return this.states.has(key); }
}

const logger: Logger = { info() {}, warn() {}, error() {} };
const environment = {
  name: "test", tenantId: "11111111-1111-4111-8111-111111111111",
  subscriptionId: "22222222-2222-4222-8222-222222222222", resourceGroup: "rg-device-notifications-test"
};

function captureLogger() {
  const entries: Array<{ message: string; properties?: Record<string, unknown> }> = [];
  const logger: Logger = {
    info: (message, properties) => entries.push({ message, properties }),
    warn: (message, properties) => entries.push({ message, properties }),
    error: (message, properties) => entries.push({ message, properties })
  };
  return { logger, entries };
}

function contractResults(entries: Array<{ message: string }>): NotificationDeliveryResult[] {
  return entries
    .filter(({ message }) => message.startsWith("AZD_NOTIFICATION_DELIVERY_RESULT "))
    .map(({ message }) => JSON.parse(message.slice("AZD_NOTIFICATION_DELIVERY_RESULT ".length)) as NotificationDeliveryResult);
}

const httpFailureCases: Array<[number, string, boolean]> = [
  [400, "invalidRequest", false],
  [401, "authentication", false],
  [403, "authorization", false],
  [404, "destinationUnavailable", false],
  [408, "timeout", true],
  [410, "destinationUnavailable", false],
  [418, "unknown", false],
  [429, "throttled", true],
  [500, "transientProvider", true],
  [503, "transientProvider", true]
];

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
      bot: { sendToEntraUser }, history, logger, routing, adminEmails: [], environment
    };
    await dispatchEvent(noncompliantEvent, dependencies);
    await dispatchEvent(noncompliantEvent, dependencies);
    expect(sendToEntraUser).toHaveBeenCalledTimes(1);
    expect(sendToEntraUser).toHaveBeenCalledWith(noncompliantEvent.owner?.id, expect.objectContaining({ type: "AdaptiveCard" }));
    expect(post).not.toHaveBeenCalled();
  });

  it("emits succeeded then already-delivered results under one canonical key", async () => {
    const captured = captureLogger();
    const history = new MemoryHistory();
    const sendToEntraUser = vi.fn(async () => undefined);
    const route = { audience: "user" as const, transport: "teamsDm" as const, severity: "high" as const };
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } }
    }));
    const dependencies = {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { sendToEntraUser }, history, logger: captured.logger, routing, adminEmails: [], environment,
      now: new Date("2026-08-23T12:00:00.000Z")
    };

    await dispatchEvent(noncompliantEvent, dependencies);
    await dispatchEvent(noncompliantEvent, dependencies);

    const results = contractResults(captured.entries);
    const envelope = normalizeDeviceNotification(noncompliantEvent, environment);
    const contractRoute = notificationContractRoute(route);
    const canonicalKey = notificationIdempotencyKey(
      environment.tenantId, envelope.eventType, envelope.eventId, contractRoute.id
    );
    expect(results.map(({ status }) => status)).toEqual(["succeeded", "alreadyDelivered"]);
    expect(results.every(({ idempotencyKey }) => idempotencyKey === canonicalKey)).toBe(true);
    expect(history.reservations.every(({ key }) => key === canonicalKey)).toBe(true);
    expect(sendToEntraUser).toHaveBeenCalledOnce();
  });

  it("recognizes a delivered legacy key but reserves new work only with the canonical key", async () => {
    const captured = captureLogger();
    const history = new MemoryHistory();
    const sendToEntraUser = vi.fn(async () => undefined);
    const route = { audience: "user" as const, transport: "teamsDm" as const, severity: "high" as const };
    const legacyKey = legacyDeliveryKey(noncompliantEvent, route);
    history.seedDelivered(legacyKey);
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } }
    }));

    await dispatchEvent(noncompliantEvent, {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { sendToEntraUser }, history, logger: captured.logger, routing, adminEmails: [], environment
    });

    const [reservation] = history.reservations;
    expect(reservation.legacyDeliveredKey).toBe(legacyKey);
    expect(reservation.key).not.toBe(legacyKey);
    expect(contractResults(captured.entries)).toMatchObject([{ status: "alreadyDelivered", attempt: 0 }]);
    expect(sendToEntraUser).not.toHaveBeenCalled();
  });

  it("honors a fresh pending legacy reservation before creating canonical state", async () => {
    const captured = captureLogger();
    const history = new MemoryHistory();
    const sendToEntraUser = vi.fn(async () => undefined);
    const route = { audience: "user" as const, transport: "teamsDm" as const, severity: "high" as const };
    const legacyKey = legacyDeliveryKey(noncompliantEvent, route);
    history.seedPending(legacyKey);
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } }
    }));

    await expect(dispatchEvent(noncompliantEvent, {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { sendToEntraUser }, history, logger: captured.logger, routing, adminEmails: [], environment
    })).rejects.toThrow("1 notification route(s) failed");

    const [reservation] = history.reservations;
    expect(reservation.legacyDeliveredKey).toBe(legacyKey);
    expect(history.hasState(reservation.key)).toBe(false);
    expect(contractResults(captured.entries)).toMatchObject([{
      status: "skipped", attempt: 0, skipReason: "concurrentDelivery"
    }]);
    expect(sendToEntraUser).not.toHaveBeenCalled();
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
      environment,
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
      adminEmails: [],
      environment
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
      bot: { sendToEntraUser }, history: new MemoryHistory(), logger, adminEmails: [], environment,
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
    const captured = captureLogger();
    const dependencies = {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { sendToEntraUser }, history, logger: captured.logger, routing, adminEmails: [], environment
    };
    const first = dispatchEvent(noncompliantEvent, dependencies);
    await vi.waitFor(() => expect(sendToEntraUser).toHaveBeenCalledOnce());
    await expect(dispatchEvent(noncompliantEvent, dependencies)).rejects.toThrow("1 notification route(s) failed");
    releaseSend();
    await first;
    await dispatchEvent(noncompliantEvent, dependencies);
    expect(sendToEntraUser).toHaveBeenCalledOnce();
    expect(contractResults(captured.entries).map(({ status }) => status)).toEqual([
      "skipped", "succeeded", "alreadyDelivered"
    ]);
    expect(contractResults(captured.entries)[0]).toMatchObject({
      attempt: 0, skipReason: "concurrentDelivery"
    });
  });

  it.each(httpFailureCases)("classifies Teams Workflow HTTP %s as %s with retryable=%s", async (status, category, retryable) => {
    const captured = captureLogger();
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: [], admin: ["teamsWebhook"] } }
    }));
    const fetcher = vi.fn(async () => new Response("sensitive provider body", { status }));
    const dispatch = dispatchEvent(noncompliantEvent, {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { async sendToEntraUser() {} }, history: new MemoryHistory(), logger: captured.logger,
      routing, adminEmails: [], environment, webhookUrl: "https://private.example.test?sig=secret", fetcher
    });

    if (retryable) await expect(dispatch).rejects.toThrow("1 notification route(s) failed");
    else await expect(dispatch).resolves.toMatchObject({ routes: [{ status: "unavailable" }] });
    expect(contractResults(captured.entries)).toMatchObject([{
      status: "failed", attempt: 1,
      evidence: { httpStatusCode: status, providerCode: `TeamsHttp${status}` },
      failure: { category, retryable, code: `TeamsHttp${status}` }
    }]);
    expect(JSON.stringify(captured.entries)).not.toMatch(/sensitive provider body|private\.example\.test|[?&]sig=/);
  });

  it("maps an unstructured Teams transport exception to a safe unknown retry", async () => {
    const captured = captureLogger();
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: [], admin: ["teamsWebhook"] } }
    }));
    const fetcher = vi.fn(async () => { throw new Error("sensitive provider exception and destination"); });

    await expect(dispatchEvent(noncompliantEvent, {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { async sendToEntraUser() {} }, history: new MemoryHistory(), logger: captured.logger,
      routing, adminEmails: [], environment, webhookUrl: "https://private.example.test?sig=secret", fetcher
    })).rejects.toThrow("1 notification route(s) failed");

    expect(contractResults(captured.entries)).toMatchObject([{
      status: "failed", evidence: { providerCode: "TeamsTransportError" },
      failure: { category: "unknown", retryable: true, code: "TeamsTransportError" }
    }]);
    expect(JSON.stringify(captured.entries)).not.toMatch(/sensitive provider|private\.example\.test|[?&]sig=/);
  });

  it.each(httpFailureCases)("classifies Graph email HTTP %s as %s with retryable=%s", async (status, category, retryable) => {
    const captured = captureLogger();
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: [], admin: ["email"] } }
    }));
    const post = vi.fn(async () => {
      throw new ProviderRequestError("microsoftGraph", `GraphHttp${status}`, status, "safe-operation-id");
    });
    const dispatch = dispatchEvent(noncompliantEvent, {
      graph: { async *pages<T>() { yield [] as T[]; }, post },
      bot: { async sendToEntraUser() {} }, history: new MemoryHistory(), logger: captured.logger,
      routing, adminEmails: ["private-admin@example.test"], emailSenderUpn: "private-sender@example.test",
      environment
    });

    if (retryable) await expect(dispatch).rejects.toThrow("1 notification route(s) failed");
    else await expect(dispatch).resolves.toMatchObject({ routes: [{ status: "unavailable" }] });
    expect(contractResults(captured.entries)).toMatchObject([{
      status: "failed", attempt: 1,
      evidence: { httpStatusCode: status, providerCode: `GraphHttp${status}`, operationId: "safe-operation-id" },
      failure: { category, retryable, code: `GraphHttp${status}` }
    }]);
    expect(JSON.stringify(captured.entries)).not.toMatch(/private-admin|private-sender|example\.test/);
  });

  it("maps a permanent provider outcome to a non-retryable safe failure", async () => {
    const captured = captureLogger();
    const routing = loadRoutingConfig(JSON.stringify({
      events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } }
    }));
    const summary = await dispatchEvent(noncompliantEvent, {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} },
      bot: { async sendToEntraUser() { throw new PermanentDeliveryError("private recipient detail"); } },
      history: new MemoryHistory(), logger: captured.logger, routing, adminEmails: [], environment
    });

    expect(summary.routes).toMatchObject([{ status: "unavailable" }]);
    expect(contractResults(captured.entries)).toMatchObject([{
      status: "failed", attempt: 1,
      failure: { category: "destinationUnavailable", retryable: false, code: "DestinationUnavailable" }
    }]);
    expect(JSON.stringify(captured.entries)).not.toContain("private recipient detail");
  });

  it("releases a failed route so a queue retry can deliver it", async () => {
    const captured = captureLogger();
    const sendToEntraUser = vi.fn()
      .mockRejectedValueOnce(new Error("sensitive-token https://private.example.test?sig=secret"))
      .mockResolvedValueOnce(undefined);
    const dependencies = {
      graph: { async *pages<T>() { yield [] as T[]; }, async post() {} }, bot: { sendToEntraUser },
      history: new MemoryHistory(), logger: captured.logger, adminEmails: [], environment,
      routing: loadRoutingConfig(JSON.stringify({ events: { deviceNoncompliant: { user: ["teamsDm"], admin: [] } } }))
    };
    await expect(dispatchEvent(noncompliantEvent, dependencies)).rejects.toThrow("1 notification route(s) failed");
    await dispatchEvent(noncompliantEvent, dependencies);
    expect(sendToEntraUser).toHaveBeenCalledTimes(2);
    expect(contractResults(captured.entries)).toMatchObject([
      { status: "failed", attempt: 1, failure: { category: "unknown", retryable: true, code: "UnknownDeliveryFailure" } },
      { status: "succeeded", attempt: 1 }
    ]);
    expect(JSON.stringify(captured.entries)).not.toMatch(/sensitive-token|private\.example\.test|[?&]sig=/);
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
