import type { HttpRequest, HttpResponseInit } from "@azure/functions";
import {
  App,
  type AppOptions,
  type IActivityContext,
  type IPlugin,
} from "@microsoft/teams.apps";
import type {
  Activity,
  ConversationReference,
  IMessageActivityInput,
} from "@microsoft/teams.api";
import {
  PermanentDeliveryError,
  type ConversationRepository,
  type Logger,
} from "./domain.js";
import type { TeamsBotSender } from "./delivery.js";
import { readBoundedJsonObject } from "./http-body.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SAFE_ERROR_CODE = /^[A-Za-z][A-Za-z0-9._-]{0,64}$/;

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function safeCode(value: unknown): string | undefined {
  return typeof value === "string" && SAFE_ERROR_CODE.test(value)
    ? value
    : undefined;
}

function safeStatus(value: unknown): number | undefined {
  return typeof value === "number" &&
    Number.isInteger(value) &&
    value >= 100 &&
    value <= 599
    ? value
    : undefined;
}

function errorType(error: unknown): string {
  return safeCode(record(error)?.name) ?? "UnknownError";
}

function classifyBotError(error: unknown): string {
  const source = record(error);
  const bodyError = record(record(source?.body)?.error);
  const code = safeCode(source?.code) ?? safeCode(bodyError?.code);
  const status = safeStatus(source?.statusCode) ?? safeStatus(source?.status);
  if (status !== undefined && code !== undefined)
    return `TeamsHttp${status}_${code}`;
  if (status !== undefined) return `TeamsHttp${status}`;
  if (code !== undefined) return `Teams${code}`;
  const name = safeCode(source?.name);
  return name ? `Teams${name}` : "TeamsBotTurnFailure";
}

function normalizedUuid(value: unknown): string | undefined {
  return typeof value === "string" && UUID.test(value)
    ? value.toLowerCase()
    : undefined;
}

function nonemptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

export class ManagedIdentityTeamsBot implements TeamsBotSender {
  private readonly app: App;
  private readonly appId: string;
  private readonly tenantId: string;
  private initialization?: Promise<void>;

  constructor(
    appId: string,
    tenantId: string,
    private readonly conversations: ConversationRepository,
    private readonly logger: Logger,
    app?: App,
  ) {
    this.appId =
      normalizedUuid(appId) ??
      (() => {
        throw Error("TeamsBotAppIdInvalid");
      })();
    this.tenantId =
      normalizedUuid(tenantId) ??
      (() => {
        throw Error("TeamsBotTenantIdInvalid");
      })();
    this.app =
      app ??
      new App({
        clientId: this.appId,
        tenantId: this.tenantId,
        managedIdentityClientId: this.appId,
        messagingEndpoint: "/api/messages",
        dangerouslyAllowUnauthenticatedRequests: false,
        logger: createSafeTeamsLogger(this.logger),
      });
    this.app.on("activity", async (context) => {
      await this.captureConversation(context);
    });
    this.app.event("error", ({ error }) => {
      this.logger.error("Teams bot turn failed", {
        code: classifyBotError(error),
        type: errorType(error),
      });
    });
  }

  async sendToEntraUser(ownerObjectId: string, card: unknown): Promise<void> {
    const owner = normalizedUuid(ownerObjectId);
    if (!owner)
      throw new PermanentDeliveryError(
        "Teams bot installation conversation unavailable",
      );
    const reference = record(
      await this.conversations.getConversation(owner),
    ) as Partial<ConversationReference> | undefined;
    if (
      !reference ||
      !nonemptyString(reference.serviceUrl) ||
      reference.channelId !== "msteams" ||
      reference.conversation?.conversationType !== "personal" ||
      reference.conversation.isGroup === true ||
      !nonemptyString(reference.conversation.id) ||
      normalizedUuid(reference.conversation.tenantId) !== this.tenantId ||
      normalizedUuid(reference.user?.aadObjectId) !== owner ||
      !nonemptyString(reference.user?.id)
    )
      throw new PermanentDeliveryError(
        "Teams bot installation conversation unavailable",
      );

    await this.initialize();
    try {
      const client = this.app.api.fromServiceUrl({
        serviceUrl: reference.serviceUrl,
      });
      const message: IMessageActivityInput = {
        type: "message",
        attachments: [
          {
            contentType: "application/vnd.microsoft.card.adaptive",
            content: card,
          },
        ],
      };
      await client.conversations.createActivity(
        reference.conversation.id,
        message,
      );
    } catch (error) {
      const code = classifyBotError(error);
      this.logger.error("Teams bot send failed", {
        code,
        type: errorType(error),
      });
      throw new Error(code);
    }
  }

  async handle(request: HttpRequest): Promise<HttpResponseInit> {
    const parsed = await readBoundedJsonObject(request);
    if (parsed.response) return parsed.response;
    await this.initialize();
    const headers: Record<string, string> = {};
    request.headers.forEach((value, name) => {
      headers[name] = value;
    });
    const response = await this.app.server.handleRequest({
      body: parsed.body,
      headers,
    });
    return { status: response.status, jsonBody: response.body };
  }

  private async initialize(): Promise<void> {
    this.initialization ??= this.app.initialize();
    await this.initialization;
  }

  private async captureConversation(
    context: IActivityContext<Activity>,
  ): Promise<void> {
    const activity = record(context.activity);
    const channelData = record(activity?.channelData);
    const activityTenant = record(channelData?.tenant);
    const conversation = record(activity?.conversation);
    const from = record(activity?.from);
    if (
      activity?.channelId !== "msteams" ||
      normalizedUuid(activityTenant?.id) !== this.tenantId ||
      conversation?.conversationType !== "personal" ||
      conversation.isGroup === true ||
      (conversation.tenantId !== undefined &&
        normalizedUuid(conversation.tenantId) !== this.tenantId)
    )
      return;

    const ownerObjectId = normalizedUuid(from?.aadObjectId);
    if (!ownerObjectId) return;
    if (
      activity.type === "installationUpdate" &&
      activity.action === "remove"
    ) {
      await this.conversations.deleteConversation(ownerObjectId);
      return;
    }
    if (
      !nonemptyString(conversation.id) ||
      !nonemptyString(from?.id) ||
      !nonemptyString(activity.serviceUrl)
    )
      return;

    const reference = record(context.ref) ?? {};
    const referenceConversation = record(reference.conversation) ?? {};
    const referenceUser = record(reference.user) ?? {};
    await this.conversations.putConversation(ownerObjectId, {
      ...reference,
      channelId: "msteams",
      serviceUrl: activity.serviceUrl,
      user: { ...referenceUser, aadObjectId: ownerObjectId },
      conversation: {
        ...referenceConversation,
        id: conversation.id,
        isGroup: false,
        conversationType: "personal",
        tenantId: this.tenantId,
      },
    });
  }
}

function createSafeTeamsLogger(
  target: Logger,
): NonNullable<AppOptions<IPlugin>["logger"]> {
  const create = (): NonNullable<AppOptions<IPlugin>["logger"]> => ({
    error() {
      target.error("Teams SDK operation failed", { code: "TeamsSdkFailure" });
    },
    warn() {},
    info() {},
    debug() {},
    trace() {},
    log(level) {
      if (level === "error")
        target.error("Teams SDK operation failed", { code: "TeamsSdkFailure" });
    },
    child() {
      return create();
    },
  });
  return create();
}
