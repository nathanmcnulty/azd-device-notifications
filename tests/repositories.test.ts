import { describe, expect, it } from "vitest";
import { AzureStateRepository, buildQueueUrl, classifyDeliveryReservation } from "../src/repositories.js";

function repositoryWithHistory(history: object): AzureStateRepository {
  const repository = Object.create(AzureStateRepository.prototype) as AzureStateRepository;
  Object.assign(repository, { ready: Promise.resolve(), history });
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
