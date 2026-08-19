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

function title(event: DeviceEvent): string {
  if (event.type === "deviceRegistered") return "Device registered";
  if (event.type === "deviceEnrolled") return "Device enrolled";
  return `Device compliance changed to ${event.complianceState ?? "unknown"}`;
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

export async function dispatchEvent(event: DeviceEvent, dependencies: DeliveryDependencies): Promise<void> {
  if (dependencies.routing.monitoredGroupIds.length) {
    const subjectId = event.owner?.id ?? event.actor?.id;
    if (!subjectId || !dependencies.graph.checkUserMemberGroups) {
      dependencies.logger.warn("Event suppressed because monitored group membership cannot be established", { eventId: event.id, eventType: event.type });
      return;
    }
    const memberships = await dependencies.graph.checkUserMemberGroups(subjectId, dependencies.routing.monitoredGroupIds);
    if (!memberships.length) return;
  }
  const failures: Error[] = [];
  for (const route of routeEvent(event, dependencies.routing, dependencies.now)) {
    const key = createHash("sha256").update(`${event.id}:${route.audience}:${route.transport}`).digest("hex");
    if (await dependencies.history.has(key)) continue;
    try {
      if (await deliver(event, route, dependencies)) {
        await dependencies.history.record(key, (dependencies.now ?? new Date()).toISOString());
        dependencies.logger.info("Notification delivered", { eventId: event.id, eventType: event.type, audience: route.audience, transport: route.transport });
      } else {
        dependencies.logger.warn("Notification route has no configured recipient", { eventId: event.id, audience: route.audience, transport: route.transport });
      }
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error));
      if (failure instanceof PermanentDeliveryError) {
        dependencies.logger.warn("Notification route is not currently available", {
          eventId: event.id, eventType: event.type, audience: route.audience, transport: route.transport, message: failure.message
        });
        continue;
      }
      failures.push(failure);
      dependencies.logger.error("Notification delivery failed", {
        eventId: event.id, eventType: event.type, audience: route.audience, transport: route.transport,
        errorName: failure.name, message: failure.message
      });
    }
  }
  if (failures.length) throw new AggregateError(failures, `${failures.length} notification route(s) failed`);
}
