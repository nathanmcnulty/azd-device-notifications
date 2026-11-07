import { HttpRequest } from "@azure/functions";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ManagedIdentityTeamsBot } from "../src/bot.js";
import { MAX_HTTP_BODY_BYTES } from "../src/http-body.js";

const adapter = vi.hoisted(() => ({ process: vi.fn(), reference: { conversation: { id: "fixture" } } }));
vi.mock("../src/node_modules/botbuilder/lib/index.js", () => ({
  ConfigurationBotFrameworkAuthentication: class {},
  CloudAdapter: class { process = adapter.process; onTurnError?: unknown; },
  TurnContext: { getConversationReference: () => adapter.reference }
}));

const conversations = { getConversation: vi.fn(), putConversation: vi.fn(), deleteConversation: vi.fn() };
const logger = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
const tenant = "11111111-1111-4111-8111-111111111111";
const owner = "22222222-2222-4222-8222-222222222222";
function input(body: string) { return new HttpRequest({ url: "https://example.invalid/messages", method: "POST", body: { string: body } }); }

beforeEach(() => { vi.resetAllMocks(); });

describe("Teams endpoint before SDK authentication", () => {
  it.each([[413, '{"text":"' + "x".repeat(MAX_HTTP_BODY_BYTES) + '"}'], [400, "{"], [400, "null"]])("rejects invalid input with %s without SDK or conversation writes", async (status, body) => {
    const bot = new ManagedIdentityTeamsBot("fixture-app", tenant, conversations, logger);
    const result = await bot.handle(input(body as string));
    expect(result.status).toBe(status);
    expect(adapter.process).not.toHaveBeenCalled();
    expect(conversations.putConversation).not.toHaveBeenCalled();
    expect(conversations.deleteConversation).not.toHaveBeenCalled();
  });

  it("keeps valid input behind SDK authentication and preserves installation storage", async () => {
    adapter.process.mockImplementation(async (request, _response, logic) => {
      expect(request.body.type).toBe("installationUpdate");
      await logic({ activity: { type: "installationUpdate", channelId: "msteams", channelData: { tenant: { id: tenant } }, conversation: { id: "fixture", conversationType: "personal" }, serviceUrl: "https://example.invalid", from: { id: "fixture-user", aadObjectId: owner } } });
    });
    const bot = new ManagedIdentityTeamsBot("fixture-app", tenant, conversations, logger);
    expect((await bot.handle(input('{"type":"installationUpdate"}'))).status).toBe(200);
    expect(adapter.process).toHaveBeenCalledOnce();
    expect(conversations.putConversation).toHaveBeenCalledExactlyOnceWith(owner, { ...adapter.reference, user: { aadObjectId: owner }, conversation: { ...adapter.reference.conversation, tenantId: tenant } });
  });

  it("does not write a conversation when SDK authentication rejects an otherwise valid object", async () => {
    adapter.process.mockRejectedValue(new Error("fixture authentication denied"));
    const bot = new ManagedIdentityTeamsBot("fixture-app", tenant, conversations, logger);
    await expect(bot.handle(input('{"type":"installationUpdate"}'))).rejects.toThrow("fixture authentication denied");
    expect(conversations.putConversation).not.toHaveBeenCalled();
    expect(conversations.deleteConversation).not.toHaveBeenCalled();
  });
});
