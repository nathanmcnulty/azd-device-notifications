import { describe, expect, it, vi } from "vitest";
import { GraphClient } from "../src/graph.js";

const credential = { async getToken() { return { token: "test-token" }; } };

describe("Graph client", () => {
  it("follows pagination links", async () => {
    const fetcher = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ value: [1], "@odata.nextLink": "https://graph.microsoft.com/v1.0/next" }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ value: [2] }), { status: 200 }));
    const pages: number[][] = [];
    for await (const page of new GraphClient(credential, fetcher).pages<number>("/items")) pages.push(page);
    expect(pages).toEqual([[1], [2]]);
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("accepts an exact v1.0 Graph URL on the default HTTPS port", async () => {
    const getToken = vi.fn(async () => ({ token: "test-token" }));
    const fetcher = vi.fn(async () => new Response(JSON.stringify({ value: [] }), { status: 200 }));

    for await (const _page of new GraphClient({ getToken }, fetcher).pages("https://graph.microsoft.com:443/v1.0/items")) {
      /* consume */
    }

    expect(getToken).toHaveBeenCalledTimes(1);
    expect(fetcher).toHaveBeenCalledWith(
      "https://graph.microsoft.com/v1.0/items",
      expect.objectContaining({ headers: expect.objectContaining({ Authorization: "Bearer test-token" }) })
    );
  });

  it.each([
    "http://graph.microsoft.com/v1.0/items",
    "https://graph.microsoft.com.evil.example/v1.0/items",
    "https://graph.microsoft.com:444/v1.0/items",
    "https://user:password@graph.microsoft.com/v1.0/items",
    "https://graph.microsoft.com/beta/items",
    "https://graph.microsoft.com/v2.0/items",
    "https://graph.microsoft.com/v1.0/items#sensitive-fragment"
  ])("rejects an unsafe initial Graph URL before acquiring a token: %s", async (path) => {
    const getToken = vi.fn(async () => ({ token: "test-token" }));
    const fetcher = vi.fn();
    const sleeper = vi.fn(async (_milliseconds: number) => undefined);

    const read = async () => {
      for await (const _page of new GraphClient({ getToken }, fetcher, sleeper).pages(path)) { /* consume */ }
    };
    await expect(read()).rejects.toThrow("Graph request URL rejected");

    expect(getToken).not.toHaveBeenCalled();
    expect(fetcher).not.toHaveBeenCalled();
    expect(sleeper).not.toHaveBeenCalled();
  });

  it.each([
    "http://graph.microsoft.com/v1.0/next",
    "https://graph.microsoft.com.evil.example/v1.0/next",
    "https://graph.microsoft.com:444/v1.0/next",
    "https://user:password@graph.microsoft.com/v1.0/next",
    "https://graph.microsoft.com/beta/next"
  ])("rejects an unsafe Graph continuation before forwarding another token: %s", async (nextLink) => {
    const getToken = vi.fn(async () => ({ token: "test-token" }));
    const fetcher = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ value: [1], "@odata.nextLink": nextLink }), { status: 200 }));
    const sleeper = vi.fn(async (_milliseconds: number) => undefined);
    const pages: number[][] = [];

    const read = async () => {
      for await (const page of new GraphClient({ getToken }, fetcher, sleeper).pages<number>("/items")) pages.push(page);
    };
    await expect(read()).rejects.toThrow("Graph request URL rejected");

    expect(pages).toEqual([[1]]);
    expect(getToken).toHaveBeenCalledTimes(1);
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(sleeper).not.toHaveBeenCalled();
  });

  it("retries a network failure and transient HTTP statuses", async () => {
    const sleeper = vi.fn(async (_milliseconds: number) => undefined);
    const fetcher = vi.fn()
      .mockRejectedValueOnce(new TypeError("socket with sensitive endpoint detail"))
      .mockResolvedValueOnce(new Response(undefined, { status: 408 }))
      .mockResolvedValueOnce(new Response(undefined, { status: 503, headers: { "Retry-After": "2" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ value: [] }), { status: 200 }));
    for await (const _page of new GraphClient(credential, fetcher, sleeper).pages("/items")) { /* consume */ }
    expect(fetcher).toHaveBeenCalledTimes(4);
    expect(sleeper.mock.calls.map(([delay]) => delay)).toEqual([1000, 2000, 2000]);
  });

  it("honors an HTTP-date Retry-After within the retry bound", async () => {
    const now = Date.parse("2026-08-22T12:00:00.000Z");
    const sleeper = vi.fn(async (_milliseconds: number) => undefined);
    const fetcher = vi.fn()
      .mockResolvedValueOnce(new Response(undefined, {
        status: 429, headers: { "Retry-After": new Date(now + 5_000).toUTCString() }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ value: [] }), { status: 200 }));
    for await (const _page of new GraphClient(credential, fetcher, sleeper, () => now).pages("/items")) { /* consume */ }
    expect(sleeper).toHaveBeenCalledWith(5_000);
  });

  it("fails permanent responses without exposing unsafe identifiers", async () => {
    const fetcher = vi.fn(async () => new Response(undefined, {
      status: 400, headers: { "request-id": "safe-request-id" }
    }));
    await expect(new GraphClient(credential, fetcher).post("/bad", {}))
      .rejects.toThrow("Graph request failed with status 400 (request-id: safe-request-id)");
    expect(fetcher).toHaveBeenCalledOnce();
  });

  it("bounds repeated network retries and sanitizes the terminal error", async () => {
    const fetcher = vi.fn(async () => { throw new TypeError("secret-url-and-token"); });
    const sleeper = vi.fn(async (_milliseconds: number) => undefined);
    await expect(new GraphClient(credential, fetcher, sleeper).post("/items", {}))
      .rejects.toThrow("Graph retry limit reached after TypeError");
    expect(fetcher).toHaveBeenCalledTimes(6);
    expect(sleeper).toHaveBeenCalledTimes(5);
  });
});
