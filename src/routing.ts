import type { Audience, DeviceEvent, EventType, Severity, Transport } from "./domain.js";

export interface EventRouteConfig {
  user: Transport[];
  admin: Transport[];
}

export interface RoutingConfig {
  events: Record<EventType, EventRouteConfig>;
  excludedOwnership: string[];
  excludedOperatingSystems: string[];
  monitoredUserIds: string[];
  monitoredGroupIds: string[];
  privilegedUserIds: string[];
  adminMentions: Array<{ name: string; upn: string }>;
  quietHours?: { start: number; end: number; timeZone: string };
}

export interface DeliveryRoute {
  audience: Audience;
  transport: Transport;
  severity: Severity;
}

const defaults: RoutingConfig = {
  events: {
    deviceRegistered: { user: ["teamsDm"], admin: ["teamsWebhook"] },
    deviceEnrolled: { user: ["teamsDm"], admin: ["teamsWebhook"] },
    deviceNoncompliant: { user: ["teamsDm", "email"], admin: ["teamsWebhook", "email"] }
  },
  excludedOwnership: [],
  excludedOperatingSystems: [],
  monitoredUserIds: [],
  monitoredGroupIds: [],
  privilegedUserIds: [],
  adminMentions: []
};

const transports = new Set<Transport>(["teamsDm", "teamsWebhook", "email"]);
const validTransports = (value: unknown, fallback: Transport[], name: string, audience: Audience): Transport[] => {
  if (value === undefined) return fallback;
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string" || !transports.has(item as Transport))) {
    throw new Error(`${name} must be an array containing only teamsDm, teamsWebhook, or email`);
  }
  if (audience === "user" && value.includes("teamsWebhook")) throw new Error(`${name} cannot contain teamsWebhook`);
  if (audience === "admin" && value.includes("teamsDm")) throw new Error(`${name} cannot contain teamsDm`);
  if (new Set(value).size !== value.length) throw new Error(`${name} cannot contain duplicate transports`);
  return value as Transport[];
};

const stringArray = (value: unknown, name: string): string[] => {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) throw new Error(`${name} must be an array of strings`);
  return value;
};

const guidArray = (value: unknown, name: string): string[] => {
  const values = stringArray(value, name);
  if (values.some((item) => !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(item))) {
    throw new Error(`${name} must contain only GUIDs`);
  }
  return values;
};

export function loadRoutingConfig(raw = process.env.ROUTING_CONFIG_JSON): RoutingConfig {
  if (!raw) return structuredClone(defaults);
  const input = JSON.parse(raw) as Partial<RoutingConfig>;
  const inputEvents = input.events ?? {} as RoutingConfig["events"];
  const events = Object.fromEntries((Object.keys(defaults.events) as EventType[]).map((type) => [type, {
    user: validTransports(inputEvents[type]?.user, defaults.events[type].user, `events.${type}.user`, "user"),
    admin: validTransports(inputEvents[type]?.admin, defaults.events[type].admin, `events.${type}.admin`, "admin")
  }])) as Record<EventType, EventRouteConfig>;
  const quietHours = input.quietHours;
  if (quietHours) {
    if (!Number.isInteger(quietHours.start) || quietHours.start < 0 || quietHours.start > 23 ||
        !Number.isInteger(quietHours.end) || quietHours.end < 0 || quietHours.end > 23 || typeof quietHours.timeZone !== "string") {
      throw new Error("quietHours requires start/end integers from 0 through 23 and a timeZone");
    }
    try { new Intl.DateTimeFormat("en-US", { timeZone: quietHours.timeZone }).format(); }
    catch { throw new Error(`quietHours.timeZone is invalid: ${quietHours.timeZone}`); }
  }
  const adminMentions = input.adminMentions ?? [];
  if (!Array.isArray(adminMentions) || adminMentions.some((mention) =>
    !mention || typeof mention.name !== "string" || typeof mention.upn !== "string" || !/^[^@\s]+@[^@\s]+$/.test(mention.upn))) {
    throw new Error("adminMentions must contain name and UPN values");
  }
  return {
    events,
    excludedOwnership: stringArray(input.excludedOwnership, "excludedOwnership"),
    excludedOperatingSystems: stringArray(input.excludedOperatingSystems, "excludedOperatingSystems"),
    monitoredUserIds: guidArray(input.monitoredUserIds, "monitoredUserIds"),
    monitoredGroupIds: guidArray(input.monitoredGroupIds, "monitoredGroupIds"),
    privilegedUserIds: guidArray(input.privilegedUserIds, "privilegedUserIds"),
    adminMentions,
    quietHours
  };
}

const normalizedIncludes = (values: string[], candidate?: string) =>
  !!candidate && values.some((item) => item.toLowerCase() === candidate.toLowerCase());

function inQuietHours(date: Date, quiet: NonNullable<RoutingConfig["quietHours"]>): boolean {
  const hour = Number(new Intl.DateTimeFormat("en-US", {
    hour: "numeric", hourCycle: "h23", timeZone: quiet.timeZone
  }).format(date));
  return quiet.start <= quiet.end ? hour >= quiet.start && hour < quiet.end : hour >= quiet.start || hour < quiet.end;
}

export function routeEvent(event: DeviceEvent, config: RoutingConfig, now = new Date()): DeliveryRoute[] {
  if (normalizedIncludes(config.excludedOwnership, event.device.ownership) ||
      normalizedIncludes(config.excludedOperatingSystems, event.device.operatingSystem)) return [];
  const severity: Severity = event.owner?.id && normalizedIncludes(config.privilegedUserIds, event.owner.id) ? "high" : event.severity;
  const quietUser = severity === "low" && config.quietHours ? inQuietHours(now, config.quietHours) : false;
  const route = config.events[event.type];
  return [
    ...(quietUser ? [] : route.user.map((transport) => ({ audience: "user" as const, transport, severity }))),
    ...route.admin.map((transport) => ({ audience: "admin" as const, transport, severity }))
  ];
}
