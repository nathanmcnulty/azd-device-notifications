import { TableClient, type TableEntity } from "@azure/data-tables";
import { DefaultAzureCredential } from "@azure/identity";
import { QueueClient } from "@azure/storage-queue";
import type {
  ConversationRepository, DeviceEvent, DeviceSnapshot, NotificationHistoryRepository, OutboxRepository,
  SnapshotRepository, WatermarkRepository
} from "./domain.js";

interface ValueEntity extends TableEntity {
  value: string;
}

interface ReservationEntity extends TableEntity {
  reservedAt?: string;
  status?: string;
}

function isConflict(error: unknown): boolean {
  return typeof error === "object" && error !== null && "statusCode" in error && (error as { statusCode?: number }).statusCode === 409;
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
    this.queue = new QueueClient(`${options.queueEndpoint}/${options.queueName}`, credential);
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

  async reserve(fingerprint: string, event: DeviceEvent): Promise<boolean> {
    await this.ready;
    try {
      await this.fingerprints.createEntity({
        partitionKey: "event", rowKey: fingerprint,
        eventType: event.type, occurredAt: event.occurredAt, reservedAt: new Date().toISOString(), status: "pending"
      });
      return true;
    } catch (error) {
      if (isConflict(error)) {
        const existing = await this.fingerprints.getEntity<ReservationEntity>("event", fingerprint);
        const reservedAt = existing.reservedAt ? new Date(existing.reservedAt).valueOf() : Number.NaN;
        if (existing.status === "pending" && (!Number.isFinite(reservedAt) || Date.now() - reservedAt > 15 * 60_000)) {
          await this.fingerprints.updateEntity({
            partitionKey: "event", rowKey: fingerprint, reservedAt: new Date().toISOString(), status: "pending", etag: existing.etag
          }, "Merge", { etag: existing.etag });
          return true;
        }
        return false;
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

  async has(key: string): Promise<boolean> {
    await this.ready;
    try {
      await this.history.getEntity("notification", key);
      return true;
    } catch (error) {
      if (typeof error === "object" && error !== null && "statusCode" in error && (error as { statusCode?: number }).statusCode === 404) return false;
      throw error;
    }
  }

  async record(key: string, sentAt: string): Promise<void> {
    await this.ready;
    await this.history.upsertEntity({ partitionKey: "notification", rowKey: key, sentAt }, "Replace");
  }
}
