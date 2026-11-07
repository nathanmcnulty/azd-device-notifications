import type { HttpRequest, HttpResponseInit } from "@azure/functions";

// Keep this in sync with FUNCTIONS_REQUEST_BODY_SIZE_LIMIT in resources.bicep.
export const MAX_HTTP_BODY_BYTES = 256 * 1024;

type JsonObjectResult = { body: Record<string, unknown>; response?: never }
  | { body?: never; response: HttpResponseInit };

export async function readBoundedJsonObject(request: Pick<HttpRequest, "headers" | "body">): Promise<JsonObjectResult> {
  const invalid = (): JsonObjectResult => ({ response: { status: 400, jsonBody: { success: false, status: "invalid", message: "Request body must be a valid JSON object." } } });
  const oversized = (): JsonObjectResult => ({ response: { status: 413, jsonBody: { success: false, status: "invalid", message: "Request body exceeds 256 KiB." } } });
  const length = request.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || !Number.isSafeInteger(Number(length)))) return invalid();
  if (length !== null && Number(length) > MAX_HTTP_BODY_BYTES) {
    // Cancellation is initiated without waiting for an untrusted producer's cleanup.
    void request.body?.cancel().catch(() => {});
    return oversized();
  }
  if (!request.body) return invalid();

  const reader = request.body.getReader();
  const chunks: Buffer[] = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) return invalid();
      bytes += value.byteLength;
      if (bytes > MAX_HTTP_BODY_BYTES) {
        void reader.cancel().catch(() => {});
        return oversized();
      }
      chunks.push(Buffer.from(value));
    }
    const parsed: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks, bytes)));
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return invalid();
    return { body: parsed as Record<string, unknown> };
  } catch {
    return invalid();
  } finally {
    reader.releaseLock();
  }
}
