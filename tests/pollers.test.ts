import { describe, expect, it } from "vitest";
import type { DeviceEvent, Logger, OutboxRepository, WatermarkRepository } from "../src/domain.js";
import type { GraphClientLike } from "../src/graph.js";
import { pollDirectoryAudits } from "../src/pollers.js";
import { registrationAudit } from "./fixtures.js";

class MemoryOutbox implements OutboxRepository {
  readonly fingerprints = new Set<string>();
  readonly queued: DeviceEvent[] = [];
  async reserve(fingerprint: string): Promise<boolean> {
    if (this.fingerprints.has(fingerprint)) return false;
    this.fingerprints.add(fingerprint);
    return true;
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
});
