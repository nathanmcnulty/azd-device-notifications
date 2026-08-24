import { DefaultAzureCredential } from "@azure/identity";

export interface GraphPage<T> {
  value: T[];
  "@odata.nextLink"?: string;
}

export interface GraphClientLike {
  pages<T>(path: string): AsyncGenerator<T[]>;
  post(path: string, body: unknown): Promise<void>;
  checkUserMemberGroups?(userId: string, groupIds: string[]): Promise<string[]>;
}

const sleep = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function validateGraphRequestUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("Graph request URL rejected");
  }

  if (
    url.protocol !== "https:"
    || url.hostname !== "graph.microsoft.com"
    || url.port !== ""
    || url.username !== ""
    || url.password !== ""
    || (url.pathname !== "/v1.0" && !url.pathname.startsWith("/v1.0/"))
    || url.hash !== ""
  ) {
    throw new Error("Graph request URL rejected");
  }

  return url.href;
}

function requestIdentifier(response: Response): string {
  for (const name of ["request-id", "client-request-id"]) {
    const value = response.headers.get(name);
    if (value && /^[a-z0-9._:-]{1,128}$/i.test(value)) return ` (${name}: ${value})`;
  }
  return "";
}

interface TokenCredentialLike {
  getToken(scope: string): Promise<{ token: string } | null>;
}

function retryDelay(response: Response, attempt: number, now: () => number): number {
  const header = response.headers.get("Retry-After");
  if (header?.trim()) {
    if (/^\d+$/.test(header.trim())) return Math.min(Number(header.trim()) * 1000, 60_000);
    const retryAt = Date.parse(header);
    if (Number.isFinite(retryAt)) return Math.min(Math.max(retryAt - now(), 0), 60_000);
  }
  return Math.min(2 ** attempt * 1000, 60_000);
}

export class GraphClient implements GraphClientLike {
  constructor(
    private readonly credential: TokenCredentialLike = new DefaultAzureCredential({
      managedIdentityClientId: process.env.MANAGED_IDENTITY_CLIENT_ID
    }),
    private readonly fetcher: typeof fetch = fetch,
    private readonly sleeper: (milliseconds: number) => Promise<unknown> = sleep,
    private readonly now: () => number = Date.now
  ) {}

  private async request(url: string, init?: RequestInit): Promise<Response> {
    const validatedUrl = validateGraphRequestUrl(url);
    for (let attempt = 0; attempt < 6; attempt++) {
      let response: Response;
      try {
        const token = await this.credential.getToken("https://graph.microsoft.com/.default");
        if (!token) throw new Error("TokenUnavailable");
        response = await this.fetcher(validatedUrl, {
          ...init,
          headers: {
            Authorization: `Bearer ${token.token}`,
            "Content-Type": "application/json",
            ...init?.headers
          }
        });
      } catch (error) {
        if (attempt === 5) {
          const errorName = error instanceof Error && /^[a-z0-9._-]{1,80}$/i.test(error.name) ? error.name : "UnknownError";
          throw new Error(`Graph retry limit reached after ${errorName}`);
        }
        await this.sleeper(Math.min(2 ** attempt * 1000, 60_000));
        continue;
      }
      if (response.ok) return response;
      const identifier = requestIdentifier(response);
      if (response.status !== 408 && response.status !== 429 && response.status < 500) {
        throw new Error(`Graph request failed with status ${response.status}${identifier}`);
      }
      if (attempt === 5) throw new Error(`Graph retry limit reached with status ${response.status}${identifier}`);
      await response.body?.cancel().catch(() => undefined);
      await this.sleeper(retryDelay(response, attempt, this.now));
    }
    throw new Error("Graph retry loop exhausted");
  }

  async *pages<T>(path: string): AsyncGenerator<T[]> {
    let next: string | undefined = path.startsWith("http") ? path : `https://graph.microsoft.com/v1.0${path}`;
    while (next) {
      const page = (await (await this.request(next)).json()) as GraphPage<T>;
      yield page.value ?? [];
      next = page["@odata.nextLink"];
    }
  }

  async post(path: string, body: unknown): Promise<void> {
    await this.request(`https://graph.microsoft.com/v1.0${path}`, {
      method: "POST",
      body: JSON.stringify(body)
    });
  }

  async checkUserMemberGroups(userId: string, groupIds: string[]): Promise<string[]> {
    const matched: string[] = [];
    for (let index = 0; index < groupIds.length; index += 20) {
      const response = await this.request(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(userId)}/checkMemberGroups`, {
        method: "POST",
        body: JSON.stringify({ groupIds: groupIds.slice(index, index + 20) })
      });
      const result = await response.json() as { value?: string[] };
      matched.push(...(result.value ?? []));
    }
    return matched;
  }
}
