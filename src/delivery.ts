import { createHash } from "node:crypto";
import { PermanentDeliveryError, type DeviceEvent, type Logger, type NotificationHistoryRepository } from "./domain.js";
import type { GraphClientLike } from "./graph.js";
import { adminLinks } from "./normalization.js";
import { routeEvent, type DeliveryRoute, type RoutingConfig } from "./routing.js";

export interface TeamsBotSender {
  sendToEntraUser(ownerObjectId: string, card: unknown): Promise<void>;
}

export interface DeliveryDependencies {
  graph: GraphClientLike;
  bot: TeamsBotSender;
  history: NotificationHistoryRepository;
  logger: Logger;
  fetcher?: typeof fetch;
  routing: RoutingConfig;
  adminEmails: string[];
  webhookUrl?: string;
  emailSenderUpn?: string;
  now?: Date;
}

export interface DeliverySummary {
  selectedRoutes: number;
  deliveredRoutes: number;
  alreadyDeliveredRoutes: number;
  unavailableRoutes: number;
  routes: Array<{ audience: "user" | "admin"; transport: string; status: "delivered" | "alreadyDelivered" | "unavailable" | "pending" | "failed" }>;
  suppressedReason?: string;
}

export class DeliveryDispatchError extends AggregateError {
  constructor(errors: Error[], message: string, readonly summary: DeliverySummary) {
    super(errors, message);
  }
}

export function validateDeliveryConfiguration(
  routing: RoutingConfig,
  destinations: Pick<DeliveryDependencies, "adminEmails" | "webhookUrl" | "emailSenderUpn">
): void {
  const routes = Object.values(routing.events);
  if (!routes.some((route) => route.user.length > 0 || route.admin.length > 0)) {
    throw new Error("At least one notification delivery route must be enabled");
  }
  if (routes.some((route) => route.admin.includes("teamsWebhook")) && !destinations.webhookUrl?.trim()) {
    throw new Error("TEAMS_ADMIN_WEBHOOK_URL is required when an admin teamsWebhook route is enabled");
  }
  if (destinations.webhookUrl) {
    let webhook: URL;
    try { webhook = new URL(destinations.webhookUrl); }
    catch { throw new Error("TEAMS_ADMIN_WEBHOOK_URL must be a valid HTTPS URL"); }
    if (webhook.protocol !== "https:") throw new Error("TEAMS_ADMIN_WEBHOOK_URL must be a valid HTTPS URL");
  }
  if (routes.some((route) => route.user.includes("email") || route.admin.includes("email")) && !destinations.emailSenderUpn?.trim()) {
    throw new Error("EMAIL_SENDER_UPN is required when an email route is enabled");
  }
  const emailPattern = /^[^@\s]+@[^@\s]+$/;
  if (destinations.emailSenderUpn && !emailPattern.test(destinations.emailSenderUpn)) {
    throw new Error("EMAIL_SENDER_UPN must be a valid address");
  }
  if (routes.some((route) => route.admin.includes("email")) && destinations.adminEmails.length === 0) {
    throw new Error("ADMIN_EMAIL_RECIPIENTS requires at least one address when an admin email route is enabled");
  }
  if (destinations.adminEmails.some((address) => !emailPattern.test(address))) {
    throw new Error("ADMIN_EMAIL_RECIPIENTS must contain valid addresses");
  }
}

function title(event: DeviceEvent): string {
  const value = event.type === "deviceRegistered" ? "Device registered"
    : event.type === "deviceEnrolled" ? "Device enrolled"
      : `Device compliance changed to ${event.complianceState ?? "unknown"}`;
  return event.synthetic ? `[TEST] ${value}` : value;
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

export function shapeAdaptiveCard(event: DeviceEvent, audience: "user" | "admin", mentions: Array<{ name: string; upn: string }> = [], severity = event.severity): unknown {
  const links = adminLinks(event);
  const facts = [
    { title: "Device", value: event.device.displayName ?? "Unknown device" },
    { title: "When", value: event.occurredAt },
    { title: "Severity", value: severity },
    ...(event.complianceState ? [{ title: "Compliance", value: event.complianceState }] : []),
    ...(event.gracePeriodExpirationDateTime ? [{ title: "Grace deadline", value: event.gracePeriodExpirationDateTime }] : [])
  ];
  const actions = audience === "admin"
    ? [links.entra && { type: "Action.OpenUrl", title: "Open in Entra", url: links.entra },
       links.intune && { type: "Action.OpenUrl", title: "Open in Intune", url: links.intune }].filter(Boolean)
    : [];
  const mentionText = audience === "admin" && mentions.length
    ? { type: "TextBlock", text: mentions.map((mention) => `<at>${mention.name}</at>`).join(" "), wrap: true }
    : undefined;
  return {
    type: "AdaptiveCard", version: "1.5", $schema: "http://adaptivecards.io/schemas/adaptive-card.json",
    body: [{ type: "TextBlock", text: title(event), weight: "Bolder", size: "Medium", wrap: true },
      mentionText, { type: "FactSet", facts }].filter(Boolean), actions,
    ...(mentionText ? { msteams: { entities: mentions.map((mention) => ({
      type: "mention", text: `<at>${mention.name}</at>`, mentioned: { id: mention.upn, name: mention.name }
    })) } } : {})
  };
}

function emailBody(event: DeviceEvent, audience: "user" | "admin", severity: string) {
  const links = adminLinks(event);
  const linkText = audience === "admin"
    ? [links.entra, links.intune].filter(Boolean).map((link) => `<p><a href="${link}">Open device administration</a></p>`).join("")
    : "";
  return `<p>${escapeHtml(title(event))}</p><p>Device: ${escapeHtml(event.device.displayName ?? "Unknown device")}</p><p>Severity: ${escapeHtml(severity)}</p>${linkText}`;
}

async function deliver(event: DeviceEvent, route: DeliveryRoute, dependencies: DeliveryDependencies): Promise<boolean> {
  const card = shapeAdaptiveCard(event, route.audience, route.transport === "teamsWebhook" ? dependencies.routing.adminMentions : [], route.severity);
  if (route.transport === "teamsDm") {
    if (route.audience !== "user" || !event.owner?.id) return false;
    await dependencies.bot.sendToEntraUser(event.owner.id, card);
    return true;
  }
  if (route.transport === "teamsWebhook") {
    if (route.audience !== "admin" || !dependencies.webhookUrl) return false;
    const response = await (dependencies.fetcher ?? fetch)(dependencies.webhookUrl, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type: "message", attachments: [{ contentType: "application/vnd.microsoft.card.adaptive", contentUrl: null, content: card }] })
    });
    if (!response.ok) throw new Error(`Teams webhook failed with status ${response.status}`);
    return true;
  }
  if (!dependencies.emailSenderUpn) return false;
  const recipients = route.audience === "admin" ? dependencies.adminEmails : [event.owner?.email ?? event.owner?.upn].filter((item): item is string => !!item);
  if (!recipients.length) return false;
  await dependencies.graph.post(`/users/${encodeURIComponent(dependencies.emailSenderUpn)}/sendMail`, {
    message: {
      subject: title(event),
      body: { contentType: "HTML", content: emailBody(event, route.audience, route.severity) },
      toRecipients: recipients.map((address) => ({ emailAddress: { address } }))
    }, saveToSentItems: false
  });
  return true;
}

export async function dispatchEvent(event: DeviceEvent, dependencies: DeliveryDependencies): Promise<DeliverySummary> {
  const summary: DeliverySummary = {
    selectedRoutes: 0, deliveredRoutes: 0, alreadyDeliveredRoutes: 0, unavailableRoutes: 0, routes: []
  };
  const subjectId = event.owner?.id ?? event.actor?.id;
  const monitoredUsers = dependencies.routing.monitoredUserIds;
  const monitoredGroups = dependencies.routing.monitoredGroupIds;
  if (monitoredUsers.length || monitoredGroups.length) {
    if (!subjectId) {
      dependencies.logger.warn("Event suppressed because the monitored subject cannot be established", { eventId: event.id, eventType: event.type });
      return { ...summary, suppressedReason: "monitored subject unavailable" };
    }
    const directlyMonitored = monitoredUsers.some((id) => id.toLowerCase() === subjectId.toLowerCase());
    if (!directlyMonitored && monitoredGroups.length && !dependencies.graph.checkUserMemberGroups) {
      dependencies.logger.warn("Event suppressed because monitored group membership cannot be established", { eventId: event.id, eventType: event.type });
      return { ...summary, suppressedReason: "group membership unavailable" };
    }
    const memberships = directlyMonitored || !monitoredGroups.length
      ? []
      : await dependencies.graph.checkUserMemberGroups!(subjectId, monitoredGroups);
    if (!directlyMonitored && !memberships.length) return { ...summary, suppressedReason: "subject outside monitored scope" };
  }
  const failures: Error[] = [];
  const routes = routeEvent(event, dependencies.routing, dependencies.now);
  summary.selectedRoutes = routes.length;
  for (const route of routes) {
    const key = createHash("sha256").update(`${event.id}:${route.audience}:${route.transport}`).digest("hex");
    const reservation = await dependencies.history.reserveDelivery(key);
    if (reservation.status === "delivered") {
      summary.alreadyDeliveredRoutes++;
      summary.routes.push({ audience: route.audience, transport: route.transport, status: "alreadyDelivered" });
      continue;
    }
    if (reservation.status === "pending") {
      summary.unavailableRoutes++;
      summary.routes.push({ audience: route.audience, transport: route.transport, status: "pending" });
      failures.push(new Error(`Notification route ${route.audience}:${route.transport} is pending delivery`));
      continue;
    }
    try {
      if (await deliver(event, route, dependencies)) {
        await dependencies.history.completeDelivery(key, reservation.etag, (dependencies.now ?? new Date()).toISOString());
        summary.deliveredRoutes++;
        summary.routes.push({ audience: route.audience, transport: route.transport, status: "delivered" });
        dependencies.logger.info("Notification delivered", { eventId: event.id, eventType: event.type, audience: route.audience, transport: route.transport });
      } else {
        await dependencies.history.releaseDelivery(key, reservation.etag);
        summary.unavailableRoutes++;
        summary.routes.push({ audience: route.audience, transport: route.transport, status: "unavailable" });
        dependencies.logger.warn("Notification route has no configured recipient", { eventId: event.id, audience: route.audience, transport: route.transport });
      }
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error));
      await dependencies.history.releaseDelivery(key, reservation.etag);
      if (failure instanceof PermanentDeliveryError) {
        summary.unavailableRoutes++;
        summary.routes.push({ audience: route.audience, transport: route.transport, status: "unavailable" });
        dependencies.logger.warn("Notification route is not currently available", {
          eventId: event.id, eventType: event.type, audience: route.audience, transport: route.transport, message: failure.message
        });
        continue;
      }
      summary.unavailableRoutes++;
      summary.routes.push({ audience: route.audience, transport: route.transport, status: "failed" });
      failures.push(failure);
      dependencies.logger.error("Notification delivery failed", {
        eventId: event.id, eventType: event.type, audience: route.audience, transport: route.transport,
        errorName: failure.name, message: failure.message
      });
    }
  }
  if (failures.length) throw new DeliveryDispatchError(failures, `${failures.length} notification route(s) failed`, summary);
  return summary;
}
