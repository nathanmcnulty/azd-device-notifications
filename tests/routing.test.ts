import { describe, expect, it } from "vitest";
import { loadRoutingConfig, routeEvent } from "../src/routing.js";
import { ids, noncompliantEvent } from "./fixtures.js";

describe("routing", () => {
  it("routes user and admin audiences independently", () => {
    const routes = routeEvent(noncompliantEvent, loadRoutingConfig());
    expect(routes.map(({ audience, transport }) => `${audience}:${transport}`)).toEqual([
      "user:teamsDm", "user:email", "admin:teamsWebhook", "admin:email"
    ]);
  });

  it("still routes admins when owner is missing", () => {
    const routes = routeEvent({ ...noncompliantEvent, owner: undefined }, loadRoutingConfig());
    expect(routes.filter((route) => route.audience === "admin")).toHaveLength(2);
  });

  it("suppresses excluded devices and low severity users during quiet hours", () => {
    const excluded = loadRoutingConfig(JSON.stringify({ excludedOperatingSystems: ["windows"] }));
    expect(routeEvent(noncompliantEvent, excluded)).toEqual([]);

    const quiet = loadRoutingConfig(JSON.stringify({ quietHours: { start: 0, end: 23, timeZone: "UTC" } }));
    const low = { ...noncompliantEvent, type: "deviceEnrolled" as const, severity: "low" as const };
    const routes = routeEvent(low, quiet, new Date("2026-08-17T10:00:00.000Z"));
    expect(routes.every((route) => route.audience === "admin")).toBe(true);
    expect(routes).toHaveLength(1);
  });

  it("elevates privileged users so quiet hours do not suppress them", () => {
    const config = loadRoutingConfig(JSON.stringify({
      privilegedUserIds: [ids.owner], quietHours: { start: 0, end: 23, timeZone: "UTC" }
    }));
    const event = { ...noncompliantEvent, type: "deviceEnrolled" as const, severity: "low" as const };
    expect(routeEvent(event, config, new Date("2026-08-17T10:00:00.000Z"))).toEqual([
      { audience: "user", transport: "teamsDm", severity: "high" },
      { audience: "admin", transport: "teamsWebhook", severity: "high" }
    ]);
  });

  it("rejects malformed routing configuration", () => {
    expect(() => loadRoutingConfig(JSON.stringify({ monitoredGroupIds: ["not-a-guid"] }))).toThrow("GUIDs");
    expect(() => loadRoutingConfig(JSON.stringify({ quietHours: { start: 30, end: 7, timeZone: "UTC" } }))).toThrow("quietHours");
    expect(() => loadRoutingConfig(JSON.stringify({ events: { deviceRegistered: { user: ["sms"] } } }))).toThrow("teamsDm");
    expect(() => loadRoutingConfig(JSON.stringify({ events: { deviceRegistered: { user: ["teamsWebhook"] } } }))).toThrow("cannot contain teamsWebhook");
    expect(() => loadRoutingConfig(JSON.stringify({ events: { deviceRegistered: { admin: ["teamsDm"] } } }))).toThrow("cannot contain teamsDm");
    expect(() => loadRoutingConfig(JSON.stringify({ events: { deviceRegistered: { user: ["email", "email"] } } }))).toThrow("duplicate transports");
  });
});
