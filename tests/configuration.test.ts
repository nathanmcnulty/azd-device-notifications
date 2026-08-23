import { describe, expect, it } from "vitest";
import { boundedNumber } from "../src/configuration.js";

describe("runtime numeric configuration", () => {
  it("uses the safe fallback and accepts inclusive bounds", () => {
    expect(boundedNumber("VALUE", undefined, 0, 0, 10)).toBe(0);
    expect(boundedNumber("VALUE", "10", 0, 0, 10)).toBe(10);
  });

  it.each(["NaN", "Infinity", "-1", "1.5", "11"])("rejects invalid value %s", (raw) => {
    expect(() => boundedNumber("VALUE", raw, 0, 0, 10)).toThrow("VALUE must be an integer from 0 through 10");
  });

  it("enforces the directory-audit overlap contract", () => {
    expect(boundedNumber("ENTRA_AUDIT_OVERLAP_MINUTES", "1", 15, 1, 1_440)).toBe(1);
    expect(() => boundedNumber("ENTRA_AUDIT_OVERLAP_MINUTES", "0", 15, 1, 1_440))
      .toThrow("ENTRA_AUDIT_OVERLAP_MINUTES must be an integer from 1 through 1440");
  });
});
