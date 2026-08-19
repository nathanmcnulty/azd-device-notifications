import type { Logger, ManagedDevice, OutboxRepository, SnapshotRepository, WatermarkRepository } from "./domain.js";
import type { GraphClientLike } from "./graph.js";
import { detectManagedDeviceEvents } from "./intune.js";
import { normalizeRegistration, type DirectoryAudit } from "./normalization.js";

async function publish(events: ReturnType<typeof normalizeRegistration>[], outbox: OutboxRepository, logger: Logger) {
  for (const event of events) {
    if (!event) continue;
    if (!(await outbox.reserve(event.id, event))) {
      logger.info("Duplicate event suppressed", { eventId: event.id, eventType: event.type });
      continue;
    }
    try {
      await outbox.enqueue(event);
    } catch (error) {
      await outbox.release(event.id);
      throw error;
    }
  }
}

export async function pollDirectoryAudits(dependencies: {
  graph: GraphClientLike;
  watermarks: WatermarkRepository;
  outbox: OutboxRepository;
  logger: Logger;
  now: Date;
  overlapMs: number;
}): Promise<void> {
  const prior = await dependencies.watermarks.get("directoryAudits");
  const from = new Date((prior ? new Date(prior).valueOf() : dependencies.now.valueOf()) - dependencies.overlapMs);
  const filter = encodeURIComponent(`activityDateTime ge ${from.toISOString()}`);
  let latest = prior ? new Date(prior) : from;
  let count = 0;
  for await (const page of dependencies.graph.pages<DirectoryAudit>(
    `/auditLogs/directoryAudits?$filter=${filter}&$orderby=activityDateTime asc&$top=100`
  )) {
    for (const audit of page) {
      const timestamp = audit.activityDateTime ? new Date(audit.activityDateTime) : undefined;
      if (timestamp && !Number.isNaN(timestamp.valueOf()) && timestamp > latest) latest = timestamp;
    }
    const events = page.map(normalizeRegistration);
    await publish(events, dependencies.outbox, dependencies.logger);
    count += events.filter(Boolean).length;
  }
  await dependencies.watermarks.set("directoryAudits", latest.toISOString());
  dependencies.logger.info("Directory audit poll completed", { normalizedEventCount: count, watermark: latest.toISOString() });
}

export async function pollManagedDevices(dependencies: {
  graph: GraphClientLike;
  snapshots: SnapshotRepository;
  outbox: OutboxRepository;
  logger: Logger;
  now: Date;
  enrollmentLookbackMs: number;
}): Promise<void> {
  let deviceCount = 0;
  let eventCount = 0;
  const select = "id,azureADDeviceId,deviceName,enrolledDateTime,complianceState,complianceGracePeriodExpirationDateTime,lastSyncDateTime,operatingSystem,managedDeviceOwnerType,userId,userPrincipalName,emailAddress,userDisplayName";
  for await (const page of dependencies.graph.pages<ManagedDevice>(`/deviceManagement/managedDevices?$select=${select}&$top=100`)) {
    for (const device of page) {
      const previous = await dependencies.snapshots.getSnapshot(device.id);
      const detected = detectManagedDeviceEvents(device, previous, dependencies.now, dependencies.enrollmentLookbackMs);
      await publish(detected.events, dependencies.outbox, dependencies.logger);
      await dependencies.snapshots.put(detected.snapshot);
      deviceCount++;
      eventCount += detected.events.length;
    }
  }
  dependencies.logger.info("Managed device poll completed", { deviceCount, normalizedEventCount: eventCount });
}
