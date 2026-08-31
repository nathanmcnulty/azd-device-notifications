import { TableClient, type TableEntity } from "@azure/data-tables";
import { DefaultAzureCredential } from "@azure/identity";
import { QueueClient } from "@azure/storage-queue";
import type {
  ConversationRepository, DeliveryReservation, DeviceEvent, DeviceSnapshot, NotificationHistoryRepository, OutboxRepository,
  SnapshotRepository, WatermarkRepository
} from "./domain.js";

interface ValueEntity extends TableEntity {
  value: string;
}

interface ReservationEntity extends TableEntity {
  reservedAt?: string;
  status?: string;
  sentAt?: string;
}

function isConflict(error: unknown): boolean {
  return typeof error === "object" && error !== null && "statusCode" in error && (error as { statusCode?: number }).statusCode === 409;
}

function hasStatus(error: unknown, statusCode: number): boolean {
  return typeof error === "object" && error !== null && "statusCode" in error &&
    (error as { statusCode?: number }).statusCode === statusCode;
}

const OUTBOX_STALE_MS = 15 * 60_000;
const DELIVERY_STALE_MS = 2 * 60_000;

export function classifyDeliveryReservation(
  entity: Pick<ReservationEntity, "status" | "sentAt" | "reservedAt">,
  now = Date.now()
): "delivered" | "pending" | undefined {
  if (entity.status === "delivered" || (!entity.status && entity.sentAt)) return "delivered";
  const reservedAt = entity.reservedAt ? new Date(entity.reservedAt).valueOf() : Number.NaN;
  if (entity.status === "pending" && Number.isFinite(reservedAt) && now - reservedAt <= DELIVERY_STALE_MS) {
    return "pending";
  }
  return undefined;
}

export function buildQueueUrl(queueEndpoint: string, queueName: string): string {
  return `${queueEndpoint.replace(/\/+$/, "")}/${queueName}`;
}

export class AzureStateRepository implements WatermarkRepository, SnapshotRepository, OutboxRepository, NotificationHistoryRepository, ConversationRepository {
  private readonly state: TableClient;
  private readonly fingerprints: TableClient;
  private readonly history: TableClient;
  private readonly queue: QueueClient;
  private readonly ready: Promise<void>;

  constructor(options: { tableEndpoint: string; queueEndpoint: string; queueName: string; managedIdentityClientId?: string }) {
    const credential = new DefaultAzureCredential({ managedIdentityClientId: options.managedIdentityClientId });
    this.state = new TableClient(options.tableEndpoint, "DeviceNotificationState", credential);
    this.fingerprints = new TableClient(options.tableEndpoint, "DeviceEventFingerprints", credential);
    this.history = new TableClient(options.tableEndpoint, "DeviceNotificationHistory", credential);
    this.queue = new QueueClient(buildQueueUrl(options.queueEndpoint, options.queueName), credential);
    this.ready = Promise.all([
      this.state.createTable().catch((error) => { if (!isConflict(error)) throw error; }),
      this.fingerprints.createTable().catch((error) => { if (!isConflict(error)) throw error; }),
      this.history.createTable().catch((error) => { if (!isConflict(error)) throw error; }),
      this.queue.createIfNotExists()
    ]).then(() => undefined);
  }

  async get(name: string): Promise<string | undefined> {
    await this.ready;
    try {
      return (await this.state.getEntity<ValueEntity>("watermark", name)).value;
    } catch (error) {
      if (typeof error === "object" && error !== null && "statusCode" in error && (error as { statusCode?: number }).statusCode === 404) return undefined;
      throw error;
    }
  }

  async set(name: string, value: string): Promise<void> {
    await this.ready;
    await this.state.upsertEntity({ partitionKey: "watermark", rowKey: name, value }, "Replace");
  }

  async put(snapshot: DeviceSnapshot): Promise<void> {
    await this.ready;
    await this.state.upsertEntity({
      partitionKey: "snapshot", rowKey: snapshot.deviceId,
      value: JSON.stringify(snapshot)
    }, "Replace");
  }

  async getSnapshot(deviceId: string): Promise<DeviceSnapshot | undefined> {
    await this.ready;
    try {
      const entity = await this.state.getEntity<ValueEntity>("snapshot", deviceId);
      return JSON.parse(entity.value) as DeviceSnapshot;
    } catch (error) {
      if (typeof error === "object" && error !== null && "statusCode" in error && (error as { statusCode?: number }).statusCode === 404) return undefined;
      throw error;
    }
  }

  async getConversation(ownerObjectId: string): Promise<unknown | undefined> {
    await this.ready;
    try {
      const entity = await this.state.getEntity<ValueEntity>("conversation", ownerObjectId);
      return JSON.parse(entity.value) as unknown;
    } catch (error) {
      if (typeof error === "object" && error !== null && "statusCode" in error && (error as { statusCode?: number }).statusCode === 404) return undefined;
      throw error;
    }
  }

  async putConversation(ownerObjectId: string, reference: unknown): Promise<void> {
    await this.ready;
    await this.state.upsertEntity({ partitionKey: "conversation", rowKey: ownerObjectId, value: JSON.stringify(reference) }, "Replace");
  }

  async deleteConversation(ownerObjectId: string): Promise<void> {
    await this.ready;
    await this.state.deleteEntity("conversation", ownerObjectId).catch((error) => {
      if (typeof error !== "object" || error === null || !("statusCode" in error) || (error as { statusCode?: number }).statusCode !== 404) throw error;
    });
  }

  async reserve(fingerprint: string, event: DeviceEvent): Promise<"reserved" | "published" | "pending"> {
    await this.ready;
    try {
      await this.fingerprints.createEntity({
        partitionKey: "event", rowKey: fingerprint,
        eventType: event.type, occurredAt: event.occurredAt, reservedAt: new Date().toISOString(), status: "pending"
      });
      return "reserved";
    } catch (error) {
      if (isConflict(error)) {
        const existing = await this.fingerprints.getEntity<ReservationEntity>("event", fingerprint);
        const reservedAt = existing.reservedAt ? new Date(existing.reservedAt).valueOf() : Number.NaN;
        if (existing.status === "published") return "published";
        if (existing.status === "pending" && (!Number.isFinite(reservedAt) || Date.now() - reservedAt >= OUTBOX_STALE_MS)) {
          try {
            await this.fingerprints.updateEntity({
              partitionKey: "event", rowKey: fingerprint, reservedAt: new Date().toISOString(), status: "pending", etag: existing.etag
            }, "Merge", { etag: existing.etag });
            return "reserved";
          } catch (updateError) {
            if (!hasStatus(updateError, 412)) throw updateError;
            const current = await this.fingerprints.getEntity<ReservationEntity>("event", fingerprint);
            return current.status === "published" ? "published" : "pending";
          }
        }
        return "pending";
      }
      throw error;
    }
  }

  async release(fingerprint: string): Promise<void> {
    await this.ready;
    await this.fingerprints.deleteEntity("event", fingerprint).catch((error) => {
      if (typeof error !== "object" || error === null || !("statusCode" in error) || (error as { statusCode?: number }).statusCode !== 404) throw error;
    });
  }

  async enqueue(event: DeviceEvent): Promise<void> {
    await this.ready;
    await this.queue.sendMessage(JSON.stringify(event));
    await this.fingerprints.updateEntity({
      partitionKey: "event", rowKey: event.id, publishedAt: new Date().toISOString(), status: "published"
    }, "Merge");
  }

  async reserveDelivery(key: string, legacyDeliveredKey?: string): Promise<DeliveryReservation> {
    await this.ready;
    if (legacyDeliveredKey && legacyDeliveredKey !== key) {
      try {
        const legacy = await this.history.getEntity<ReservationEntity>("notification", legacyDeliveredKey);
        const legacyState = classifyDeliveryReservation(legacy);
        if (legacyState) return { status: legacyState };
      } catch (error) {
        if (!hasStatus(error, 404)) throw error;
      }
    }
    try {
      await this.history.createEntity({
        partitionKey: "notification", rowKey: key, reservedAt: new Date().toISOString(), status: "pending"
      });
      const created = await this.history.getEntity<ReservationEntity>("notification", key);
      if (!created.etag) throw new Error("Delivery reservation did not return an ETag");
      return { status: "reserved", etag: created.etag };
    } catch (error) {
      if (!isConflict(error)) throw error;
      const existing = await this.history.getEntity<ReservationEntity>("notification", key);
      const existingState = classifyDeliveryReservation(existing);
      if (existingState) return { status: existingState };
      try {
        await this.history.updateEntity({
          partitionKey: "notification", rowKey: key, reservedAt: new Date().toISOString(), status: "pending", etag: existing.etag
        }, "Merge", { etag: existing.etag });
        const recovered = await this.history.getEntity<ReservationEntity>("notification", key);
        if (!recovered.etag) throw new Error("Recovered delivery reservation did not return an ETag");
        return { status: "reserved", etag: recovered.etag };
      } catch (updateError) {
        if (!hasStatus(updateError, 412)) throw updateError;
        const current = await this.history.getEntity<ReservationEntity>("notification", key);
        return current.status === "delivered" || (!current.status && current.sentAt)
          ? { status: "delivered" }
          : { status: "pending" };
      }
    }
  }

  async releaseDelivery(key: string, etag: string): Promise<void> {
    await this.ready;
    await this.history.deleteEntity("notification", key, { etag }).catch((error) => {
      if (!hasStatus(error, 404) && !hasStatus(error, 412)) throw error;
    });
  }

  async completeDelivery(key: string, etag: string, sentAt: string): Promise<void> {
    await this.ready;
    await this.history.updateEntity({
      partitionKey: "notification", rowKey: key, status: "delivered", sentAt, etag
    }, "Merge", { etag });
  }
}
