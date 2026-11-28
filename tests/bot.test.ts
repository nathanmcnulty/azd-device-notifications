import { HttpRequest } from "@azure/functions";
import { describe, expect, it } from "vitest";
import { ManagedIdentityTeamsBot } from "../src/bot.js";
import { MAX_HTTP_BODY_BYTES } from "../src/http-body.js";
import { createTestTeamsApp } from "./teams-app-fixture.js";

const tenant = "11111111-1111-4111-8111-111111111111";
const owner = "22222222-2222-4222-8222-222222222222";
const appId = "33333333-3333-4333-8333-333333333333";
const message = {
  type: "installationUpdate",
  channelId: "msteams",
  channelData: { tenant: { id: tenant } },
  from: { id: "fixture-user", aadObjectId: owner },
  recipient: { id: "fixture-bot" },
  conversation: {
    id: "fixture-conversation",
    conversationType: "personal",
    isGroup: false,
  },
  serviceUrl: "https://example.invalid",
};

function input(body: string) {
  return new HttpRequest({
    url: "https://example.invalid/messages",
    method: "POST",
    body: { string: body },
  });
}

function repository() {
  return {
    getConversation: async () => undefined,
    putConversation: async () => {},
    deleteConversation: async () => {},
  };
}

const logger = { info() {}, warn() {}, error() {} };

describe("Teams endpoint before SDK authentication", () => {
  it.each([
    [413, `{"text":"${"x".repeat(MAX_HTTP_BODY_BYTES)}"}`],
    [400, "{"],
    [400, "null"],
  ])(
    "rejects invalid input with %s without invoking the Teams SDK",
    async (status, body) => {
      const sdk = createTestTeamsApp();
      const bot = new ManagedIdentityTeamsBot(
        appId,
        tenant,
        repository(),
        logger,
        sdk.app,
      );
      const result = await bot.handle(input(body as string));
      expect(result.status).toBe(status);
      expect(sdk.initializationCalls).toBe(0);
      expect(sdk.requestCalls).toBe(0);
    },
  );

  it("passes a valid activity to the injected Teams SDK callback", async () => {
    const sdk = createTestTeamsApp();
    const writes: unknown[] = [];
    const bot = new ManagedIdentityTeamsBot(
      appId,
      tenant,
      {
        ...repository(),
        async putConversation(id, reference) {
          writes.push({ id, reference });
        },
      },
      logger,
      sdk.app,
    );
    const result = await bot.handle(input(JSON.stringify(message)));
    expect(result.status).toBe(200);
    expect(sdk.initializationCalls).toBe(1);
    expect(sdk.requestCalls).toBe(1);
    expect(writes).toHaveLength(1);
    expect(writes[0]).toMatchObject({
      id: owner,
      reference: {
        channelId: "msteams",
        conversation: { id: "fixture-conversation", tenantId: tenant },
        user: { aadObjectId: owner },
      },
    });
  });

  it("rejects an unsigned request with the real SDK before conversation storage", async () => {
    const calls: string[] = [];
    const bot = new ManagedIdentityTeamsBot(
      appId,
      tenant,
      {
        async getConversation() {
          calls.push("get");
          return undefined;
        },
        async putConversation() {
          calls.push("put");
        },
        async deleteConversation() {
          calls.push("delete");
        },
      },
      logger,
    );
    const result = await bot.handle(input(JSON.stringify(message)));
    expect(result.status).toBe(401);
    expect(calls).toEqual([]);
  });
});
