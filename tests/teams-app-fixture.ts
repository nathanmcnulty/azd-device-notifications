import type { App } from "../src/node_modules/@microsoft/teams.apps";

type TestContext = {
  activity: Record<string, unknown>;
  ref: Record<string, unknown>;
};

export function createTestTeamsApp() {
  let activityHandler: (context: TestContext) => Promise<void> = async () => {};
  let initializationCalls = 0;
  let requestCalls = 0;
  const sent: Array<{
    conversationId: string;
    serviceUrl: string;
    activity: unknown;
  }> = [];
  const app = {
    on(name: string, handler: (context: TestContext) => Promise<void>) {
      if (name === "activity") activityHandler = handler;
      return app;
    },
    event() {
      return app;
    },
    async initialize() {
      initializationCalls++;
    },
    server: {
      async handleRequest(request: { body: unknown }) {
        requestCalls++;
        const activity = request.body as Record<string, unknown>;
        await activityHandler({
          activity,
          ref: {
            channelId: activity.channelId,
            serviceUrl: activity.serviceUrl,
            activityId: activity.id,
            bot: activity.recipient,
            conversation: activity.conversation,
            locale: activity.locale,
            user: activity.from,
          },
        });
        return { status: 200 };
      },
    },
    api: {
      fromServiceUrl({ serviceUrl }: { serviceUrl: string }) {
        return {
          conversations: {
            async createActivity(conversationId: string, activity: unknown) {
              sent.push({ conversationId, serviceUrl, activity });
              return {};
            },
          },
        };
      },
    },
  };
  return {
    app: app as unknown as App,
    sent,
    get initializationCalls() {
      return initializationCalls;
    },
    get requestCalls() {
      return requestCalls;
    },
  };
}
