import { describe, expect, it } from "vitest";
import { classifyDeliveryReservation } from "../src/repositories.js";

describe("delivery reservation migration", () => {
  const now = Date.parse("2026-08-23T12:02:00.000Z");

  it("recognizes current and legacy delivered shapes", () => {
    expect(classifyDeliveryReservation({ status: "delivered" }, now)).toBe("delivered");
    expect(classifyDeliveryReservation({ sentAt: "2026-08-23T12:00:00.000Z" }, now)).toBe("delivered");
  });

  it("honors a fresh pending reservation through the same two-minute threshold", () => {
    expect(classifyDeliveryReservation({
      status: "pending", reservedAt: "2026-08-23T12:00:00.000Z"
    }, now)).toBe("pending");
    expect(classifyDeliveryReservation({
      status: "pending", reservedAt: "2026-08-23T12:00:00.001Z"
    }, now)).toBe("pending");
  });

  it("allows recovery only after a pending reservation becomes stale", () => {
    expect(classifyDeliveryReservation({
      status: "pending", reservedAt: "2026-08-23T11:59:59.999Z"
    }, now)).toBeUndefined();
    expect(classifyDeliveryReservation({ status: "pending", reservedAt: "invalid" }, now)).toBeUndefined();
  });
});
