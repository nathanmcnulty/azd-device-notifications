import type { HttpRequest, HttpResponseInit } from "@azure/functions";
import {
  CloudAdapter, ConfigurationBotFrameworkAuthentication, TurnContext,
  type ConversationReference
} from "botbuilder";
import { PermanentDeliveryError, type ConversationRepository, type Logger } from "./domain.js";
import type { TeamsBotSender } from "./delivery.js";
import { readBoundedJsonObject } from "./http-body.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function normalizedUuid(value: unknown): string | undefined {
  return typeof value === "string" && UUID.test(value) ? value.toLowerCase() : undefined;
}
function nonemptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

interface WebResponseCapture {
  statusCode: number;
  headers: Record<string, string>;
  body?: unknown;
  socket: unknown;
  header(name: string, value: unknown): void;
  setHeader(name: string, value: string): void;
  status(code: number): WebResponseCapture;
  send(body?: unknown): void;
  end(body?: unknown): void;
}

export class ManagedIdentityTeamsBot implements TeamsBotSender {
  private readonly adapter: CloudAdapter;
  private readonly tenantId: string;

  constructor(
    private readonly appId: string,
    tenantId: string,
    private readonly conversations: ConversationRepository,
    private readonly logger: Logger
  ) {
    this.tenantId = normalizedUuid(tenantId) ?? (() => { throw Error("TeamsBotTenantIdInvalid"); })();
    const authentication = new ConfigurationBotFrameworkAuthentication({
      MicrosoftAppType: "UserAssignedMSI",
      MicrosoftAppId: appId,
      MicrosoftAppPassword: "",
      MicrosoftAppTenantId: tenantId
    });
    this.adapter = new CloudAdapter(authentication);
    this.adapter.onTurnError = async () => {
      this.logger.error("Teams bot turn failed", { code: "TeamsBotTurnFailure" });
    };
  }

  async sendToEntraUser(ownerObjectId: string, card: unknown): Promise<void> {
    const owner = normalizedUuid(ownerObjectId);
    if (!owner) throw new PermanentDeliveryError("Teams bot installation conversation unavailable");
    const reference = await this.conversations.getConversation(owner) as Partial<ConversationReference> | undefined;
    if (!reference || !nonemptyString(reference.serviceUrl)
      || reference.channelId !== "msteams" || reference.conversation?.conversationType !== "personal"
      || reference.conversation.isGroup === true || !nonemptyString(reference.conversation.id)
      || normalizedUuid(reference.conversation.tenantId) !== this.tenantId
      || normalizedUuid(reference.user?.aadObjectId) !== owner || !nonemptyString(reference.user?.id)) {
      throw new PermanentDeliveryError("Teams bot installation conversation unavailable");
    }
    await this.adapter.continueConversationAsync(this.appId, reference as ConversationReference, async (context) => {
      await context.sendActivity({ attachments: [{ contentType: "application/vnd.microsoft.card.adaptive", content: card }] });
    });
  }

  async handle(request: HttpRequest): Promise<HttpResponseInit> {
    const parsed = await readBoundedJsonObject(request);
    if (parsed.response) return parsed.response;
    const body = parsed.body;
    const response: WebResponseCapture = {
      statusCode: 200,
      headers: {},
      socket: undefined,
      header(name, value) { this.headers[name] = String(value); },
      setHeader(name, value) { this.headers[name] = value; },
      status(code) { this.statusCode = code; return this; },
      send(value) { this.body = value; },
      end(value) { this.body = value; }
    };
    const headers: Record<string, string> = {};
    request.headers.forEach((value, name) => { headers[name] = value; });
    const webRequest = { method: request.method, headers, body };
    await this.adapter.process(webRequest, response, async (context) => {
      const conversation = context.activity.conversation;
      if (context.activity.channelId !== "msteams"
        || normalizedUuid(context.activity.channelData?.tenant?.id) !== this.tenantId
        || conversation?.conversationType !== "personal" || conversation.isGroup === true
        || (conversation.tenantId !== undefined && normalizedUuid(conversation.tenantId) !== this.tenantId)) return;
      const ownerObjectId = normalizedUuid(context.activity.from?.aadObjectId);
      if (ownerObjectId) {
        const installationAction = (context.activity as { action?: string }).action;
        if (context.activity.type === "installationUpdate" && installationAction === "remove") {
          await this.conversations.deleteConversation(ownerObjectId);
        } else {
          if (!nonemptyString(conversation.id) || !nonemptyString(context.activity.from?.id) || !nonemptyString(context.activity.serviceUrl)) return;
          const reference = TurnContext.getConversationReference(context.activity);
          await this.conversations.putConversation(ownerObjectId, {
            ...reference,
            user: { ...reference.user!, aadObjectId: ownerObjectId },
            conversation: { ...reference.conversation!, tenantId: this.tenantId }
          });
        }
      }
    });
    return { status: response.statusCode, headers: response.headers, body: typeof response.body === "string" ? response.body : undefined, jsonBody: typeof response.body === "object" ? response.body : undefined };
  }
}
