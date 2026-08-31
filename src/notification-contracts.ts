import { createHash } from "node:crypto";
import type { DeviceEvent, Logger } from "./domain.js";
import type { DeliveryRoute } from "./routing.js";

export interface NotificationEnvironment {
  name: string;
  tenantId: string;
  subscriptionId: string;
  resourceGroup: string;
}

export interface NotificationEnvelope {
  schemaVersion: "1.0";
  eventId: string;
  eventType: "entra.device.registered" | "intune.device.enrolled" | "intune.device.complianceChanged";
  source: "microsoftGraph.directoryAudit" | "microsoftGraph.deviceManagement";
  occurredAt: string;
  severity: "low" | "medium" | "high";
  correlationId: string;
  isTest: boolean;
  environment: NotificationEnvironment;
  data: Record<string, unknown>;
}

export interface NotificationContractRoute {
  id: "user-teams-dm" | "admin-teams-workflow" | "user-email" | "admin-email";
  audience: "user" | "admin";
  transport: "teams.bot" | "teams.workflowWebhook" | "email.graph";
}

type FailureCategory =
  | "authentication"
  | "authorization"
  | "throttled"
  | "timeout"
  | "transientProvider"
  | "invalidRequest"
  | "destinationUnavailable"
  | "unknown";

export interface NotificationEvidence {
  httpStatusCode?: number;
  providerCode?: string;
  operationId?: string;
}

export interface NotificationDeliveryResult {
  schemaVersion: "1.0";
  eventId: string;
  eventType: NotificationEnvelope["eventType"];
  correlationId: string;
  idempotencyKey: string;
  route: NotificationContractRoute;
  status: "succeeded" | "alreadyDelivered" | "skipped" | "failed";
  attempt: number;
  recordedAt: string;
  isTest: boolean;
  environment: NotificationEnvironment;
  durationMs?: number;
  skipReason?: "concurrentDelivery";
  evidence: NotificationEvidence;
  failure?: { category: FailureCategory; retryable: boolean; code: string };
}

type DeliveryResultMetadata = { attempt: number; recordedAt: Date; durationMs?: number; evidence?: NotificationEvidence };
type DeliveryResultOptions = DeliveryResultMetadata & (
  | { status: "succeeded" | "alreadyDelivered" }
  | { status: "skipped"; skipReason: "concurrentDelivery" }
  | { status: "failed"; failure: NonNullable<NotificationDeliveryResult["failure"]> }
);

const eventMappings = {
  deviceRegistered: { eventType: "entra.device.registered", source: "microsoftGraph.directoryAudit" },
  deviceEnrolled: { eventType: "intune.device.enrolled", source: "microsoftGraph.deviceManagement" },
  deviceNoncompliant: { eventType: "intune.device.complianceChanged", source: "microsoftGraph.deviceManagement" }
} as const;

function requiredSetting(source: NodeJS.ProcessEnv, name: string, maximumLength: number): string {
  const value = source[name]?.trim();
  if (!value || value.length > maximumLength) throw new Error(`Notification environment setting ${name} is invalid`);
  return value;
}

function contractIdentifier(value: string, name: string): string {
  if (!/^[A-Za-z0-9][A-Za-z0-9._:|-]{0,255}$/.test(value)) {
    throw new Error(`Notification ${name} is invalid`);
  }
  return value;
}

export function loadNotificationEnvironment(source: NodeJS.ProcessEnv = process.env): NotificationEnvironment {
  const tenantId = requiredSetting(source, "AZURE_TENANT_ID", 36);
  const subscriptionId = requiredSetting(source, "AZURE_SUBSCRIPTION_ID", 36);
  const guid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!guid.test(tenantId) || !guid.test(subscriptionId)) {
    throw new Error("Notification environment tenant or subscription identifier is invalid");
  }
  return {
    name: requiredSetting(source, "AZURE_ENV_NAME", 128),
    tenantId,
    subscriptionId,
    resourceGroup: requiredSetting(source, "AZURE_RESOURCE_GROUP", 256)
  };
}

export function normalizeDeviceNotification(
  event: DeviceEvent,
  environment: NotificationEnvironment
): NotificationEnvelope {
  const eventId = contractIdentifier(event.id, "event identifier");
  const correlationId = contractIdentifier(event.correlationId ?? eventId, "correlation identifier");
  const occurredAt = new Date(event.occurredAt);
  if (Number.isNaN(occurredAt.valueOf())) throw new Error("Notification occurrence time is invalid");
  const mapping = eventMappings[event.type];
  return {
    schemaVersion: "1.0",
    eventId,
    eventType: mapping.eventType,
    source: mapping.source,
    occurredAt: occurredAt.toISOString(),
    severity: event.severity,
    correlationId,
    isTest: event.synthetic === true,
    environment: { ...environment },
    data: {
      device: { ...event.device },
      ...(event.actor ? { actor: { ...event.actor } } : {}),
      ...(event.owner ? { owner: { ...event.owner } } : {}),
      ...(event.previousComplianceState ? { previousComplianceState: event.previousComplianceState } : {}),
      ...(event.complianceState ? { complianceState: event.complianceState } : {}),
      ...(event.gracePeriodExpirationDateTime ? { gracePeriodExpirationDateTime: event.gracePeriodExpirationDateTime } : {})
    }
  };
}

export function notificationContractRoute(route: DeliveryRoute): NotificationContractRoute {
  if (route.transport === "teamsDm" && route.audience === "user") {
    return { id: "user-teams-dm", audience: "user", transport: "teams.bot" };
  }
  if (route.transport === "teamsWebhook" && route.audience === "admin") {
    return { id: "admin-teams-workflow", audience: "admin", transport: "teams.workflowWebhook" };
  }
  if (route.transport === "email") {
    return route.audience === "user"
      ? { id: "user-email", audience: "user", transport: "email.graph" }
      : { id: "admin-email", audience: "admin", transport: "email.graph" };
  }
  throw new Error("Notification route is invalid");
}

export function notificationIdempotencyKey(
  tenantId: string,
  eventType: string,
  eventId: string,
  routeId: string
): string {
  return createHash("sha256")
    .update(`${tenantId}\n${eventType}\n${eventId}\n${routeId}`, "utf8")
    .digest("hex");
}

export function legacyDeliveryKey(event: DeviceEvent, route: DeliveryRoute): string {
  return createHash("sha256").update(`${event.id}:${route.audience}:${route.transport}`, "utf8").digest("hex");
}

export function newNotificationDeliveryResult(
  envelope: NotificationEnvelope,
  route: NotificationContractRoute,
  options: DeliveryResultOptions
): NotificationDeliveryResult {
  return {
    schemaVersion: "1.0",
    eventId: envelope.eventId,
    eventType: envelope.eventType,
    correlationId: envelope.correlationId,
    idempotencyKey: notificationIdempotencyKey(
      envelope.environment.tenantId,
      envelope.eventType,
      envelope.eventId,
      route.id
    ),
    route: { ...route },
    status: options.status,
    attempt: options.attempt,
    recordedAt: options.recordedAt.toISOString(),
    isTest: envelope.isTest,
    environment: { ...envelope.environment },
    ...(options.durationMs === undefined ? {} : { durationMs: Math.max(0, Math.trunc(options.durationMs)) }),
    ...(options.status === "skipped" ? { skipReason: options.skipReason } : {}),
    evidence: { ...(options.evidence ?? {}) },
    ...(options.status === "failed" ? { failure: { ...options.failure } } : {})
  };
}

export function recordNotificationDeliveryResult(logger: Logger, result: NotificationDeliveryResult): void {
  logger.info(`AZD_NOTIFICATION_DELIVERY_RESULT ${JSON.stringify(result)}`);
}
