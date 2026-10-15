import { describe, expect, it } from "vitest";
import { createRequire } from "node:module";
import { join } from "node:path";
import { AzureStateRepository, buildQueueUrl, classifyDeliveryReservation } from "../src/repositories.js";
import type { DeviceEvent } from "../src/domain.js";

const requireFromSource = createRequire(join(__dirname, "../src/package.json"));
const { AnonymousCredential, QueueClient } = requireFromSource("@azure/storage-queue");

function repositoryWithHistory(history: object): AzureStateRepository {
  const repository = Object.create(AzureStateRepository.prototype) as AzureStateRepository;
  Object.assign(repository, { ready: Promise.resolve(), history });
  return repository;
}

function repositoryWithState(state: object): AzureStateRepository {
  const repository = Object.create(AzureStateRepository.prototype) as AzureStateRepository;
  Object.assign(repository, { ready: Promise.resolve(), state });
  return repository;
}

describe("Azure Queue endpoint normalization", () => {
  it("joins Azure endpoints with exactly one path separator", () => {
    expect(buildQueueUrl("https://storage.queue.core.windows.net/", "device-notifications"))
      .toBe("https://storage.queue.core.windows.net/device-notifications");
    expect(buildQueueUrl("https://storage.queue.core.windows.net", "device-notifications"))
      .toBe("https://storage.queue.core.windows.net/device-notifications");
  });
});

describe("Azure Queue transport boundary", () => {
  const event: DeviceEvent = {
    id: "event-unicode-1",
    type: "deviceRegistered",
    occurredAt: "2026-10-15T18:00:00.000Z",
    severity: "low",
    device: { displayName: "R&D <'lab'> \"quoted\" / 東京 🚀" }
  };

  function repositoryWithQueue(httpClient: { sendRequest: (request: any) => Promise<any> }, updateEntity: () => Promise<void>) {
    const repository = Object.create(AzureStateRepository.prototype) as AzureStateRepository;
    const queue = new QueueClient(
      "https://storage.queue.core.windows.net/device-events",
      new AnonymousCredential(),
      { httpClient, retryOptions: { maxTries: 1 } }
    );
    Object.assign(repository, {
      ready: Promise.resolve(),
      queue,
      fingerprints: { updateEntity }
    });
    return repository;
  }

  it("sends escaped JSON through the SDK and marks published only after an accepted response", async () => {
    let published = false;
    let requestBody = "";
    const repository = repositoryWithQueue({
      async sendRequest(request) {
        expect(published).toBe(false);
        requestBody = String(request.body);
        return { request, headers: request.headers.clone(), status: 201, bodyAsText: "" };
      }
    }, async () => { published = true; });

    await repository.enqueue(event);

    const encodedMessage = requestBody.match(/<MessageText>([^<]+)<\/MessageText>/)?.[1];
    expect(encodedMessage).toBeDefined();
    expect(requestBody).toContain("&lt;");
    expect(requestBody).toContain("&amp;");
    const decodedMessage = encodedMessage!.replaceAll("&quot;", '"').replaceAll("&apos;", "'")
      .replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&");
    expect(decodedMessage).toBe(JSON.stringify(event));
    expect(JSON.parse(decodedMessage)).toEqual(event);
    expect(decodedMessage).toContain("\\\"");
    expect(decodedMessage).toContain("東京 🚀");
    expect(published).toBe(true);
  });

  it("propagates a queue failure and does not mark the event published", async () => {
    let published = false;
    const repository = repositoryWithQueue({
      async sendRequest(request) {
        return { request, headers: request.headers.clone(), status: 503, bodyAsText: "temporarily unavailable" };
      }
    }, async () => { published = true; });

    await expect(repository.enqueue(event)).rejects.toThrow();
    expect(published).toBe(false);
  });
});

describe("delivery reservation ownership", () => {
  it("uses the create response ETag even if another worker advances the row before a later read", async () => {
    let currentEtag = "worker-b-send-started";
    const history = {
      createEntity: async () => ({ etag: "worker-a-created" }),
      getEntity: async () => ({ status: "sendStarted", etag: currentEtag }),
      updateEntity: async (_entity: unknown, _mode: string, options: { etag: string }) => {
        if (options.etag !== currentEtag) throw Object.assign(new Error("lost reservation"), { statusCode: 412 });
        currentEtag = "worker-a-send-started";
        return { etag: currentEtag };
      }
    };
    const repository = repositoryWithHistory(history);
    const reservation = await repository.reserveDelivery("event:route");
    expect(reservation).toEqual({ status: "reserved", etag: "worker-a-created" });
    if (reservation.status !== "reserved") throw new Error("Expected a reservation");
    await expect(repository.markDeliveryStarted("event:route", reservation.etag)).rejects.toMatchObject({ statusCode: 412 });
    expect(currentEtag).toBe("worker-b-send-started");
  });

  it("uses the stale-reclaim write ETag even if another worker takes ownership afterward", async () => {
    let currentEtag = "worker-b-send-started";
    let reads = 0;
    const history = {
      createEntity: async () => { throw Object.assign(new Error("exists"), { statusCode: 409 }); },
      getEntity: async () => {
        reads += 1;
        return reads === 1
          ? { status: "reserved", reservedAt: "2000-01-01T00:00:00.000Z", etag: "stale" }
          : { status: "sendStarted", etag: currentEtag };
      },
      updateEntity: async (_entity: unknown, _mode: string, options: { etag: string }) => {
        if (options.etag === "stale") return { etag: "worker-a-reclaimed" };
        if (options.etag !== currentEtag) throw Object.assign(new Error("lost reservation"), { statusCode: 412 });
        currentEtag = "worker-a-send-started";
        return { etag: currentEtag };
      }
    };
    const repository = repositoryWithHistory(history);
    const reservation = await repository.reserveDelivery("event:route");
    expect(reservation).toEqual({ status: "reserved", etag: "worker-a-reclaimed" });
    if (reservation.status !== "reserved") throw new Error("Expected a reservation");
    await expect(repository.markDeliveryStarted("event:route", reservation.etag)).rejects.toMatchObject({ statusCode: 412 });
    expect(currentEtag).toBe("worker-b-send-started");
  });
});

describe("delivery reservation migration", () => {
  const now = Date.parse("2026-08-23T12:02:00.000Z");

  it("recognizes current and legacy delivered shapes", () => {
    expect(classifyDeliveryReservation({ status: "delivered" }, now)).toBe("delivered");
    expect(classifyDeliveryReservation({ sentAt: "2026-08-23T12:00:00.000Z" }, now)).toBe("delivered");
  });

  it("honors a fresh pending reservation through the same two-minute threshold", () => {
    expect(classifyDeliveryReservation({
      status: "pending", reservedAt: "2026-08-23T12:00:00.000Z"
    }, now)).toBe("pending");
    expect(classifyDeliveryReservation({
      status: "pending", reservedAt: "2026-08-23T12:00:00.001Z"
    }, now)).toBe("pending");
  });

  it("recovers only a stale reservation known to precede the provider send", () => {
    expect(classifyDeliveryReservation({
      status: "reserved", reservedAt: "2026-08-23T11:59:59.999Z"
    }, now)).toBeUndefined();
    expect(classifyDeliveryReservation({ status: "reserved", reservedAt: "invalid" }, now)).toBe("pending");
    expect(classifyDeliveryReservation({ status: "pending", reservedAt: "2026-08-23T11:59:59.999Z" }, now))
      .toBe("reviewRequired");
    expect(classifyDeliveryReservation({ status: "sendStarted", reservedAt: "2026-08-23T11:59:59.999Z" }, now))
      .toBe("reviewRequired");
    expect(classifyDeliveryReservation({ status: "pending", reservedAt: "invalid" }, now)).toBe("reviewRequired");
  });
});

describe("conversation identity boundaries", () => {
  it("keeps a foreign owner's conversation from satisfying the target lookup", async () => {
    const rows = new Map<string, string>();
    const state = {
      async getEntity(_partitionKey: string, rowKey: string) {
        const value = rows.get(rowKey);
        if (value === undefined) throw Object.assign(new Error("missing"), { statusCode: 404 });
        return { value };
      },
      async upsertEntity(entity: { rowKey: string; value: string }) {
        rows.set(entity.rowKey, entity.value);
      },
      async deleteEntity(_partitionKey: string, rowKey: string) {
        if (!rows.delete(rowKey)) throw Object.assign(new Error("missing"), { statusCode: 404 });
      }
    };
    const repository = repositoryWithState(state);
    const owner = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const foreignOwner = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";

    await repository.putConversation(foreignOwner, { conversation: "foreign" });
    expect(await repository.getConversation(owner)).toBeUndefined();
    await repository.putConversation(owner, { conversation: "owner" });
    expect(await repository.getConversation(owner)).toEqual({ conversation: "owner" });
    expect(await repository.getConversation(foreignOwner)).toEqual({ conversation: "foreign" });

    await repository.deleteConversation(owner);
    expect(await repository.getConversation(owner)).toBeUndefined();
    expect(await repository.getConversation(foreignOwner)).toEqual({ conversation: "foreign" });
  });
});
