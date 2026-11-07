import assert from "node:assert/strict";
import azureFunctions from "@azure/functions";
import { CloudAdapter, type Activity, type TurnContext } from "../src/node_modules/botbuilder/lib/index.js";
import { it as test, afterEach, vi } from "vitest";
import { ManagedIdentityTeamsBot } from "../src/bot.js";
const { HttpRequest } = azureFunctions;
const initializesStorage = false;
afterEach(() => vi.restoreAllMocks());
function patchProcess(fn: (...args: unknown[]) => Promise<void>) { vi.spyOn(CloudAdapter.prototype, "process").mockImplementation(fn); }
function patchContinue(fn: (...args: unknown[]) => Promise<void>) { vi.spyOn(CloudAdapter.prototype, "continueConversationAsync").mockImplementation(fn); }

const tenant = "11111111-1111-4111-8111-111111111111";
const owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const foreign = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
function activity(): Partial<Activity> {
  return { type: "installationUpdate", channelId: "msteams", channelData: { tenant: { id: tenant } }, from: { id: "fixture-user", name: "fixture", aadObjectId: owner.toUpperCase() }, recipient: { id: "fixture-bot", name: "fixture" }, conversation: { id: "fixture-conversation", name: "fixture", isGroup: false, conversationType: "personal" }, serviceUrl: "https://example.invalid" };
}
function reference() {
  return { channelId: "msteams", serviceUrl: "https://example.invalid", conversation: { id: "fixture-conversation", isGroup: false, conversationType: "personal", tenantId: tenant }, user: { id: "fixture-user", aadObjectId: owner }, bot: { id: "fixture-bot" } };
}
function fixture(initial?: unknown) {
  let stored = initial;
  const calls: string[] = []; const reads: string[] = []; const writtenOwners: string[] = [];
  const repository = {
    async init() { calls.push("init"); },
    async getConversation(id: string) { reads.push(id); return stored; },
    async putConversation(id: string, value: unknown) { calls.push("put"); writtenOwners.push(id); stored = value; },
    async deleteConversation(id: string) { calls.push("delete"); writtenOwners.push(id); }
  };
  const bot = new ManagedIdentityTeamsBot("33333333-3333-4333-8333-333333333333", tenant, repository, { info() {}, warn() {}, error() {} });
  return { bot, calls, reads, writtenOwners, stored: () => stored };
}
function input(message: Partial<Activity>) {
  return new HttpRequest({ url: "https://example.invalid/messages", method: "POST", body: { string: JSON.stringify(message) } });
}
function authenticate(message: Partial<Activity>) {
  patchProcess(async (...args: unknown[]) => {
    await (args[2] as (context: TurnContext) => Promise<void>)({ activity: message } as TurnContext);
  });
}
test("real SDK unsigned activity cannot touch conversation storage", async () => {
  const f = fixture();
  assert.equal((await f.bot.handle(input(activity()))).status, 401);
  assert.deepEqual(f.calls, []); assert.deepEqual(f.reads, []);
});
for (const scope of ["foreign-tenant", "foreign-channel", "group", "contradictory-group", "missing-owner", "malformed-owner", "conversation-tenant-mismatch", "conversation-tenant-malformed", "missing-conversation-id", "missing-user-id", "missing-service-url"]) {
  test(`authenticated capture rejects ${scope} before storage`, async () => {
    const message = activity();
    if (scope === "foreign-tenant") message.channelData = { tenant: { id: foreign } };
    if (scope === "foreign-channel") message.channelId = "directline";
    if (scope === "group") message.conversation!.conversationType = "groupChat";
    if (scope === "contradictory-group") message.conversation!.isGroup = true;
    if (scope === "missing-owner") delete message.from!.aadObjectId;
    if (scope === "malformed-owner") message.from!.aadObjectId = "invalid";
    if (scope === "conversation-tenant-mismatch") message.conversation!.tenantId = foreign;
    if (scope === "conversation-tenant-malformed") message.conversation!.tenantId = "invalid";
    if (scope === "missing-conversation-id") message.conversation!.id = "";
    if (scope === "missing-user-id") message.from!.id = "";
    if (scope === "missing-service-url") message.serviceUrl = "";
    authenticate(message);
    const f = fixture();
    assert.equal((await f.bot.handle(input(message))).status, 200);
    assert.deepEqual(f.calls, []); assert.deepEqual(f.reads, []);
  });
}
for (const valid of [true, false]) {
  test(`personal installation removal requires matching scope: ${valid}`, async () => {
    const message = { ...activity(), action: "remove" };
    if (!valid) message.channelData = { tenant: { id: foreign } };
    authenticate(message);
    const f = fixture();
    await f.bot.handle(input(message));
    assert.deepEqual(f.calls, valid ? (initializesStorage ? ["init", "delete"] : ["delete"]) : []);
    assert.deepEqual(f.writtenOwners, valid ? [owner] : []);
  });
}
test("SDK reference capture round-trips into one simulated proactive send", async () => {
  const message = activity();
  authenticate(message);
  const f = fixture();
  await f.bot.handle(input(message));
  const stored = f.stored() as ReturnType<typeof reference>;
  assert.equal(stored.conversation.tenantId, tenant);
  assert.equal(stored.user.aadObjectId, owner);
  assert.deepEqual(f.calls, initializesStorage ? ["init", "put"] : ["put"]);
  let continued = 0; let sent = 0;
  patchContinue(async (...args: unknown[]) => {
    continued++;
    assert.equal(args[1], stored);
    await (args[2] as (context: TurnContext) => Promise<void>)({ sendActivity: async () => { sent++; } } as unknown as TurnContext);
  });
  await f.bot.sendToEntraUser(owner.toUpperCase(), { type: "AdaptiveCard" });
  assert.deepEqual(f.reads, [owner]); assert.equal(continued, 1); assert.equal(sent, 1);
});
for (const scope of ["missing", "legacy-no-tenant", "foreign-tenant", "foreign-owner", "missing-owner", "foreign-channel", "group", "contradictory-group", "empty-url", "malformed-id"]) {
  test(`stored ${scope} reference cannot reach provider or change storage`, async () => {
    const stored = reference();
    if (scope === "legacy-no-tenant") delete (stored.conversation as Partial<typeof stored.conversation>).tenantId;
    if (scope === "foreign-tenant") stored.conversation.tenantId = foreign;
    if (scope === "foreign-owner") stored.user.aadObjectId = foreign;
    if (scope === "missing-owner") delete (stored.user as Partial<typeof stored.user>).aadObjectId;
    if (scope === "foreign-channel") stored.channelId = "directline";
    if (scope === "group") stored.conversation.conversationType = "groupChat";
    if (scope === "contradictory-group") stored.conversation.isGroup = true;
    if (scope === "empty-url") stored.serviceUrl = " ";
    if (scope === "malformed-id") (stored.conversation as unknown as { id: unknown }).id = 42;
    const f = fixture(scope === "missing" ? undefined : stored);
    let continued = 0;
    patchContinue(async () => { continued++; });
    await assert.rejects(f.bot.sendToEntraUser(owner, {}));
    assert.equal(continued, 0); assert.deepEqual(f.calls, []);
    if (scope !== "missing") assert.equal(f.stored(), stored);
  });
}
test("malformed requested owner is refused before a storage read", async () => {
  const f = fixture(reference());
  await assert.rejects(f.bot.sendToEntraUser("invalid", {}));
  assert.deepEqual(f.reads, []); assert.deepEqual(f.calls, []);
});
