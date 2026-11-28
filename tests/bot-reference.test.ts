import assert from "node:assert/strict";
import { it as test } from "vitest";
import azureFunctions from "@azure/functions";
import { ManagedIdentityTeamsBot } from "../src/bot.js";
import { createTestTeamsApp } from "./teams-app-fixture.js";

const { HttpRequest } = azureFunctions;
const tenant = "11111111-1111-4111-8111-111111111111";
const owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const foreign = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
interface TestActivity {
  type: string;
  action?: string;
  channelId: string;
  channelData: { tenant: { id: string } };
  from: { id: string; name: string; aadObjectId?: string };
  recipient: { id: string; name: string };
  conversation: {
    id: string;
    name: string;
    isGroup?: boolean;
    conversationType: string;
    tenantId?: string;
  };
  serviceUrl: string;
}

function activity(): TestActivity {
  return {
    type: "installationUpdate",
    channelId: "msteams",
    channelData: { tenant: { id: tenant } },
    from: {
      id: "fixture-user",
      name: "fixture",
      aadObjectId: owner.toUpperCase(),
    },
    recipient: { id: "fixture-bot", name: "fixture" },
    conversation: {
      id: "fixture-conversation",
      name: "fixture",
      isGroup: false,
      conversationType: "personal",
    },
    serviceUrl: "https://example.invalid",
  };
}

function reference() {
  return {
    channelId: "msteams",
    serviceUrl: "https://example.invalid",
    conversation: {
      id: "fixture-conversation",
      isGroup: false,
      conversationType: "personal",
      tenantId: tenant,
    },
    user: { id: "fixture-user", aadObjectId: owner },
    bot: { id: "fixture-bot" },
  };
}

function fixture(initial?: unknown) {
  let stored = initial;
  const calls: string[] = [];
  const reads: string[] = [];
  const writtenOwners: string[] = [];
  const repository = {
    async getConversation(id: string) {
      reads.push(id);
      return stored;
    },
    async putConversation(id: string, value: unknown) {
      calls.push("put");
      writtenOwners.push(id);
      stored = value;
    },
    async deleteConversation(id: string) {
      calls.push("delete");
      writtenOwners.push(id);
    },
  };
  const sdk = createTestTeamsApp();
  const bot = new ManagedIdentityTeamsBot(
    "33333333-3333-4333-8333-333333333333",
    tenant,
    repository,
    { info() {}, warn() {}, error() {} },
    sdk.app,
  );
  return { bot, calls, reads, writtenOwners, stored: () => stored, sdk };
}

function input(message: TestActivity) {
  return new HttpRequest({
    url: "https://example.invalid/messages",
    method: "POST",
    body: { string: JSON.stringify(message) },
  });
}

test("simulated authenticated personal installation capture stores a scoped reference", async () => {
  const f = fixture();
  assert.equal((await f.bot.handle(input(activity()))).status, 200);
  const stored = f.stored() as ReturnType<typeof reference>;
  assert.equal(stored.conversation.tenantId, tenant);
  assert.equal(stored.user.aadObjectId, owner);
  assert.equal(stored.conversation.id, "fixture-conversation");
  assert.deepEqual(f.calls, ["put"]);
  assert.equal(f.sdk.initializationCalls, 1);
});

for (const scope of [
  "foreign-tenant",
  "foreign-channel",
  "group",
  "contradictory-group",
  "missing-owner",
  "malformed-owner",
  "conversation-tenant-mismatch",
  "conversation-tenant-malformed",
  "missing-conversation-id",
  "missing-user-id",
  "missing-service-url",
]) {
  test(`simulated authenticated capture rejects ${scope} before storage`, async () => {
    const message = activity();
    if (scope === "foreign-tenant")
      message.channelData = { tenant: { id: foreign } };
    if (scope === "foreign-channel") message.channelId = "directline";
    if (scope === "group") message.conversation.conversationType = "groupChat";
    if (scope === "contradictory-group") message.conversation.isGroup = true;
    if (scope === "missing-owner") delete message.from.aadObjectId;
    if (scope === "malformed-owner") message.from.aadObjectId = "invalid";
    if (scope === "conversation-tenant-mismatch")
      message.conversation.tenantId = foreign;
    if (scope === "conversation-tenant-malformed")
      message.conversation.tenantId = "invalid";
    if (scope === "missing-conversation-id") message.conversation.id = "";
    if (scope === "missing-user-id") message.from.id = "";
    if (scope === "missing-service-url") message.serviceUrl = "";
    const f = fixture();
    assert.equal((await f.bot.handle(input(message))).status, 200);
    assert.deepEqual(f.calls, []);
    assert.deepEqual(f.reads, []);
  });
}

for (const valid of [true, false]) {
  test(`simulated installation removal requires matching scope: ${valid}`, async () => {
    const message = { ...activity(), action: "remove" };
    if (!valid) message.channelData = { tenant: { id: foreign } };
    const f = fixture();
    await f.bot.handle(input(message));
    assert.deepEqual(f.calls, valid ? ["delete"] : []);
    assert.deepEqual(f.writtenOwners, valid ? [owner] : []);
  });
}

test("captured reference is passed to the fake Teams API as an Adaptive Card", async () => {
  const f = fixture();
  await f.bot.handle(input(activity()));
  await f.bot.sendToEntraUser(owner.toUpperCase(), {
    type: "AdaptiveCard",
    version: "1.5",
    body: [],
  });
  assert.deepEqual(f.reads, [owner]);
  assert.equal(f.sdk.sent.length, 1);
  assert.equal(f.sdk.sent[0].conversationId, "fixture-conversation");
  assert.equal(f.sdk.sent[0].serviceUrl, "https://example.invalid");
  assert.deepEqual(JSON.parse(JSON.stringify(f.sdk.sent[0].activity)), {
    type: "message",
    attachments: [
      {
        contentType: "application/vnd.microsoft.card.adaptive",
        content: { type: "AdaptiveCard", version: "1.5", body: [] },
      },
    ],
  });
});

for (const scope of [
  "missing",
  "legacy-no-tenant",
  "foreign-tenant",
  "foreign-owner",
  "missing-owner",
  "foreign-channel",
  "group",
  "contradictory-group",
  "empty-url",
  "malformed-id",
]) {
  test(`stored ${scope} reference cannot reach provider or change storage`, async () => {
    const stored = reference();
    if (scope === "legacy-no-tenant")
      delete (stored.conversation as Partial<typeof stored.conversation>)
        .tenantId;
    if (scope === "foreign-tenant") stored.conversation.tenantId = foreign;
    if (scope === "foreign-owner") stored.user.aadObjectId = foreign;
    if (scope === "missing-owner")
      delete (stored.user as Partial<typeof stored.user>).aadObjectId;
    if (scope === "foreign-channel") stored.channelId = "directline";
    if (scope === "group") stored.conversation.conversationType = "groupChat";
    if (scope === "contradictory-group") stored.conversation.isGroup = true;
    if (scope === "empty-url") stored.serviceUrl = " ";
    if (scope === "malformed-id")
      (stored.conversation as unknown as { id: unknown }).id = 42;
    const f = fixture(scope === "missing" ? undefined : stored);
    await assert.rejects(f.bot.sendToEntraUser(owner, {}));
    assert.equal(f.sdk.sent.length, 0);
    assert.deepEqual(f.calls, []);
    if (scope !== "missing") assert.equal(f.stored(), stored);
  });
}

test("malformed requested owner is refused before a storage read", async () => {
  const f = fixture(reference());
  await assert.rejects(f.bot.sendToEntraUser("invalid", {}));
  assert.deepEqual(f.reads, []);
  assert.deepEqual(f.calls, []);
  assert.equal(f.sdk.sent.length, 0);
});
