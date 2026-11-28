import assert from 'node:assert/strict';
import azureFunctions from '@azure/functions';
import { ManagedIdentityTeamsBot } from '../dist/src/bot.js';

const { HttpRequest } = azureFunctions;
const appId = '11111111-1111-4111-8111-111111111111';
const tenantId = '22222222-2222-4222-8222-222222222222';
const noStorage = () => assert.fail('An unsigned activity must not access conversation storage');
const bot = new ManagedIdentityTeamsBot(appId, tenantId, {
  getConversation: noStorage,
  putConversation: noStorage,
  deleteConversation: noStorage,
}, { info() {}, warn() {}, error() {} });

const post = (value) => bot.handle(new HttpRequest({
  method: 'POST',
  url: 'http://localhost/api/messages',
  headers: { 'content-type': 'application/json' },
  body: { string: JSON.stringify(value) },
}));
assert.equal((await post([])).status, 400, 'Non-object activity must be rejected');
assert.equal((await post({
  type: 'message',
  channelId: 'msteams',
  serviceUrl: 'https://smba.trafficmanager.net/teams/',
  conversation: { id: 'synthetic-conversation', conversationType: 'personal', tenantId },
  from: { id: 'synthetic-user', aadObjectId: '33333333-3333-4333-8333-333333333333' },
  recipient: { id: 'synthetic-bot' },
})).status, 401, 'Real BotBuilder must reject an unsigned Teams activity');

console.log('Real BotBuilder startup and 400/401 request boundary passed.');
