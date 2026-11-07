import { HttpRequest } from "@azure/functions";
import { ReadableStream } from "node:stream/web";
import { describe, expect, it, vi } from "vitest";
import { MAX_HTTP_BODY_BYTES, readBoundedJsonObject } from "../src/http-body.js";

function request(text: string, headers?: Record<string, string>) {
  return new HttpRequest({ url: "https://example.invalid/messages", method: "POST", headers, body: { string: text } });
}

describe("HTTP input allocation boundary", () => {
  it("accepts a real Azure request at the exact UTF-8 byte limit", async () => {
    const prefix = '{"text":"'; const suffix = '"}';
    const text = "é".repeat((MAX_HTTP_BODY_BYTES - prefix.length - suffix.length - 1) / 2) + "x";
    const body = prefix + text + suffix;
    expect(Buffer.byteLength(body)).toBe(MAX_HTTP_BODY_BYTES);
    expect((await readBoundedJsonObject(request(body))).body).toEqual({ text });
  });

  it.each([undefined, "2"])("counts chunked bytes despite content-length %s and stops at overflow", async (length) => {
    const cancel = vi.fn(); let pulls = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) { pulls++; controller.enqueue(new Uint8Array(16 * 1024).fill(32)); },
      cancel
    }, { highWaterMark: 0 });
    const headers = new Headers(length === undefined ? {} : { "content-length": length });
    expect((await readBoundedJsonObject({ headers, body })).response?.status).toBe(413);
    expect(pulls).toBe(17);
    expect(cancel).toHaveBeenCalledOnce();
    expect(body.locked).toBe(false);
  });

  it("rejects a declared oversized body before reading it", async () => {
    const pull = vi.fn(); const cancel = vi.fn();
    const body = new ReadableStream<Uint8Array>({ pull, cancel }, { highWaterMark: 0 });
    const headers = new Headers({ "content-length": String(MAX_HTTP_BODY_BYTES + 1) });
    expect((await readBoundedJsonObject({ headers, body })).response?.status).toBe(413);
    expect(pull).not.toHaveBeenCalled(); expect(cancel).toHaveBeenCalledOnce();
  });

  it.each(["{", "null", "[]", '"text"', "0", ""])("returns 400 for invalid/non-object input %j", async (body) => {
    expect((await readBoundedJsonObject(request(body))).response?.status).toBe(400);
  });

  it("rejects invalid UTF-8 without replacement decoding", async () => {
    const input = new HttpRequest({ url: "https://example.invalid/messages", method: "POST", body: { bytes: new Uint8Array([123,34,120,34,58,34,255,34,125]) } });
    expect((await readBoundedJsonObject(input)).response?.status).toBe(400);
  });

  it("returns a safe 400 for an interrupted stream", async () => {
    const body = new ReadableStream<Uint8Array>({ pull(controller) { controller.error(new Error("private producer detail")); } });
    const result = await readBoundedJsonObject({ headers: new Headers(), body });
    expect(result.response?.status).toBe(400);
    expect(JSON.stringify(result)).not.toContain("private producer detail");
    expect(body.locked).toBe(false);
  });
});
