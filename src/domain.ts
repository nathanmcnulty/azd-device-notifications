export type EventType = "deviceRegistered" | "deviceEnrolled" | "deviceNoncompliant";
export type Severity = "low" | "medium" | "high";
export type Audience = "user" | "admin";
export type Transport = "teamsDm" | "teamsWebhook" | "email";

export interface DeviceEvent {
  id: string;
  type: EventType;
  occurredAt: string;
  severity: Severity;
  correlationId?: string;
  synthetic?: boolean;
  device: {
    id?: string;
    azureADDeviceId?: string;
    displayName?: string;
    operatingSystem?: string;
    ownership?: string;
  };
  actor?: { id?: string; displayName?: string; upn?: string };
  owner?: { id?: string; displayName?: string; upn?: string; email?: string };
  previousComplianceState?: string;
  complianceState?: string;
  gracePeriodExpirationDateTime?: string;
}

export interface ManagedDevice {
  id: string;
  azureADDeviceId?: string;
  deviceName?: string;
  enrolledDateTime?: string;
  complianceState?: string;
  complianceGracePeriodExpirationDateTime?: string;
  lastSyncDateTime?: string;
  operatingSystem?: string;
  managedDeviceOwnerType?: string;
  userId?: string;
  userPrincipalName?: string;
  emailAddress?: string;
  userDisplayName?: string;
}

export interface DeviceSnapshot {
  deviceId: string;
  firstSeenAt: string;
  enrolledDateTime?: string;
  complianceState: string;
  complianceGracePeriodExpirationDateTime?: string;
  lastSyncDateTime?: string;
}

export interface WatermarkRepository {
  get(name: string): Promise<string | undefined>;
  set(name: string, value: string): Promise<void>;
}

export interface SnapshotRepository {
  getSnapshot(deviceId: string): Promise<DeviceSnapshot | undefined>;
  put(snapshot: DeviceSnapshot): Promise<void>;
}

export interface ConversationRepository {
  getConversation(ownerObjectId: string): Promise<unknown | undefined>;
  putConversation(ownerObjectId: string, reference: unknown): Promise<void>;
  deleteConversation(ownerObjectId: string): Promise<void>;
}

export class PermanentDeliveryError extends Error {}

export interface OutboxRepository {
  reserve(fingerprint: string, event: DeviceEvent): Promise<"reserved" | "published" | "pending">;
  release(fingerprint: string): Promise<void>;
  enqueue(event: DeviceEvent): Promise<void>;
}

export type DeliveryReservation =
  | { status: "reserved"; etag: string }
  | { status: "delivered" }
  | { status: "pending" };

export interface NotificationHistoryRepository {
  reserveDelivery(key: string, legacyDeliveredKey?: string): Promise<DeliveryReservation>;
  releaseDelivery(key: string, etag: string): Promise<void>;
  completeDelivery(key: string, etag: string, sentAt: string): Promise<void>;
}

export interface Logger {
  info(message: string, properties?: Record<string, unknown>): void;
  warn(message: string, properties?: Record<string, unknown>): void;
  error(message: string, properties?: Record<string, unknown>): void;
}
