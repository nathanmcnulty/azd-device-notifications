import { describe, expect, it } from "vitest";
import type { DeviceEvent, Logger, OutboxRepository, SnapshotRepository, WatermarkRepository } from "../src/domain.js";
import type { GraphClientLike } from "../src/graph.js";
import { pollDirectoryAudits, pollManagedDevices } from "../src/pollers.js";
import { managedDevice, registrationAudit } from "./fixtures.js";

class MemoryOutbox implements OutboxRepository {
  readonly fingerprints = new Set<string>();
  readonly pending = new Set<string>();
  readonly queued: DeviceEvent[] = [];
  async reserve(fingerprint: string): Promise<"reserved" | "published" | "pending"> {
    if (this.pending.has(fingerprint)) return "pending";
    if (this.fingerprints.has(fingerprint)) return "published";
    this.fingerprints.add(fingerprint);
    return "reserved";
  }
  async release(fingerprint: string) { this.fingerprints.delete(fingerprint); }
  async enqueue(event: DeviceEvent) { this.queued.push(event); }
}

const logger: Logger = { info() {}, warn() {}, error() {} };

describe("directory audit poller", () => {
  it("suppresses a duplicate normalized event", async () => {
    const graph: GraphClientLike = {
      async *pages<T>() { yield [registrationAudit] as T[]; },
      async post() {}
    };
    const values = new Map<string, string>();
    const watermarks: WatermarkRepository = {
      async get(name) { return values.get(name); },
      async set(name, value) { values.set(name, value); }
    };
    const outbox = new MemoryOutbox();
    const dependencies = { graph, watermarks, outbox, logger, now: new Date("2026-08-17T10:05:00.000Z"), overlapMs: 900_000 };
    await pollDirectoryAudits(dependencies);
    await pollDirectoryAudits(dependencies);
    expect(outbox.queued).toHaveLength(1);
  });

  it("queries overlap so a delayed audit older than the watermark is still processed", async () => {
    let requestedPath = "";
    const graph: GraphClientLike = {
      async *pages<T>(path: string) { requestedPath = path; yield [registrationAudit] as T[]; },
      async post() {}
    };
    let watermark = "2026-08-17T10:10:00.000Z";
    const watermarks: WatermarkRepository = {
      async get() { return watermark; }, async set(_name, value) { watermark = value; }
    };
    const outbox = new MemoryOutbox();
    await pollDirectoryAudits({ graph, watermarks, outbox, logger, now: new Date("2026-08-17T10:15:00.000Z"), overlapMs: 900_000 });
    expect(decodeURIComponent(requestedPath)).toContain("activityDateTime ge 2026-08-17T09:55:00.000Z");
    expect(outbox.queued).toHaveLength(1);
    expect(watermark).toBe("2026-08-17T10:10:00.000Z");
  });

  it("does not advance the watermark while a prior reservation is still pending", async () => {
    const graph: GraphClientLike = { async *pages<T>() { yield [registrationAudit] as T[]; }, async post() {} };
    let writes = 0;
    const watermarks: WatermarkRepository = { async get() { return undefined; }, async set() { writes++; } };
    const outbox = new MemoryOutbox();
    const eventId = (await import("../src/normalization.js")).normalizeRegistration(registrationAudit)!.id;
    outbox.pending.add(eventId);
    await expect(pollDirectoryAudits({ graph, watermarks, outbox, logger, now: new Date("2026-08-17T10:05:00.000Z"), overlapMs: 900_000 }))
      .rejects.toThrow("pending publication");
    expect(writes).toBe(0);
  });

  it("does not advance an Intune snapshot after a crash leaves the event reservation pending", async () => {
    const graph: GraphClientLike = { async *pages<T>() { yield [managedDevice] as T[]; }, async post() {} };
    let snapshotWrites = 0;
    const snapshots: SnapshotRepository = {
      async getSnapshot() { return undefined; }, async put() { snapshotWrites++; }
    };
    const outbox = new MemoryOutbox();
    const detected = (await import("../src/intune.js")).detectManagedDeviceEvents(
      managedDevice, undefined, new Date("2026-08-17T10:00:00.000Z"), 24 * 3_600_000
    );
    outbox.pending.add(detected.events[0].id);
    await expect(pollManagedDevices({
      graph, snapshots, outbox, logger, now: new Date("2026-08-17T10:00:00.000Z"), enrollmentLookbackMs: 24 * 3_600_000
    })).rejects.toThrow("pending publication");
    expect(snapshotWrites).toBe(0);
  });

  it("does not read or mutate collection state while onboarding is disabled", async () => {
    let calls = 0;
    const graph: GraphClientLike = { async *pages<T>() { calls++; yield [] as T[]; }, async post() {} };
    const watermarks: WatermarkRepository = { async get() { calls++; return undefined; }, async set() { calls++; } };
    await pollDirectoryAudits({
      graph, watermarks, outbox: new MemoryOutbox(), logger, now: new Date(), overlapMs: 0, enabled: false
    });
    expect(calls).toBe(0);

    const snapshots: SnapshotRepository = {
      async getSnapshot() { calls++; return undefined; }, async put() { calls++; }
    };
    await pollManagedDevices({
      graph, snapshots, outbox: new MemoryOutbox(), logger, now: new Date(), enrollmentLookbackMs: 0, enabled: false
    });
    expect(calls).toBe(0);
  });
});
