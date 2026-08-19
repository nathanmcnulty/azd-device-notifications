import { app, type InvocationContext, type Timer } from "@azure/functions";
import type { DeviceEvent, Logger } from "./domain.js";
import { ManagedIdentityTeamsBot } from "./bot.js";
import { dispatchEvent } from "./delivery.js";
import { GraphClient } from "./graph.js";
import { pollDirectoryAudits, pollManagedDevices } from "./pollers.js";
import { AzureStateRepository } from "./repositories.js";
import { loadRoutingConfig } from "./routing.js";

const required = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} must be configured`);
  return value;
};

const storageAccount = required("STORAGE_ACCOUNT_NAME");
const state = new AzureStateRepository({
  tableEndpoint: process.env.TABLE_ENDPOINT ?? `https://${storageAccount}.table.core.windows.net`,
  queueEndpoint: process.env.QUEUE_ENDPOINT ?? `https://${storageAccount}.queue.core.windows.net`,
  queueName: process.env.NOTIFICATION_QUEUE_NAME ?? "device-notifications",
  managedIdentityClientId: process.env.MANAGED_IDENTITY_CLIENT_ID
});
const graph = new GraphClient();
const routing = loadRoutingConfig();

const logger = (context: InvocationContext): Logger => ({
  info: (message, properties) => context.log(message, properties ?? {}),
  warn: (message, properties) => context.warn(message, properties ?? {}),
  error: (message, properties) => context.error(message, properties ?? {})
});

const bot = new ManagedIdentityTeamsBot(required("TEAMS_BOT_APP_ID"), required("AZURE_TENANT_ID"), state, {
  info: (message, properties) => console.info(JSON.stringify({ level: "info", message, ...properties })),
  warn: (message, properties) => console.warn(JSON.stringify({ level: "warn", message, ...properties })),
  error: (message, properties) => console.error(JSON.stringify({ level: "error", message, ...properties }))
});

app.timer("pollDirectoryAudits", {
  schedule: process.env.ENTRA_POLL_SCHEDULE ?? "0 */5 * * * *",
  useMonitor: true,
  handler: async (_timer: Timer, context: InvocationContext) => pollDirectoryAudits({
    graph, watermarks: state, outbox: state, logger: logger(context), now: new Date(),
    overlapMs: Number(process.env.ENTRA_AUDIT_OVERLAP_MINUTES ?? "15") * 60_000
  })
});

app.timer("pollManagedDevices", {
  schedule: process.env.INTUNE_POLL_SCHEDULE ?? "30 */5 * * * *",
  useMonitor: true,
  handler: async (_timer: Timer, context: InvocationContext) => pollManagedDevices({
    graph, snapshots: state, outbox: state, logger: logger(context), now: new Date(),
    enrollmentLookbackMs: Number(process.env.ENROLLMENT_LOOKBACK_HOURS ?? "24") * 3_600_000
  })
});

app.storageQueue("dispatchDeviceNotification", {
  queueName: process.env.NOTIFICATION_QUEUE_NAME ?? "device-notifications",
  connection: "AzureWebJobsStorage",
  handler: async (message: unknown, context: InvocationContext) => {
    const event = (typeof message === "string" ? JSON.parse(message) : message) as DeviceEvent;
    await dispatchEvent(event, {
      graph, bot, history: state, logger: logger(context), routing,
      adminEmails: (process.env.ADMIN_EMAIL_RECIPIENTS ?? "").split(",").map((item) => item.trim()).filter(Boolean),
      webhookUrl: process.env.TEAMS_ADMIN_WEBHOOK_URL,
      emailSenderUpn: process.env.EMAIL_SENDER_UPN
    });
  }
});

app.http("teamsMessages", {
  route: "messages",
  methods: ["POST"],
  authLevel: "anonymous",
  handler: (request) => bot.handle(request)
});
