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

export class GraphClient implements GraphClientLike {
  constructor(
    private readonly credential = new DefaultAzureCredential({
      managedIdentityClientId: process.env.MANAGED_IDENTITY_CLIENT_ID
    }),
    private readonly fetcher: typeof fetch = fetch
  ) {}

  private async request(url: string, init?: RequestInit): Promise<Response> {
    for (let attempt = 0; attempt < 6; attempt++) {
      const token = await this.credential.getToken("https://graph.microsoft.com/.default");
      const response = await this.fetcher(url, {
        ...init,
        headers: {
          Authorization: `Bearer ${token.token}`,
          "Content-Type": "application/json",
          ...init?.headers
        }
      });
      if (response.ok) return response;
      if (response.status !== 429 && response.status < 500) {
        throw new Error(`Graph request failed with status ${response.status}`);
      }
      if (attempt === 5) throw new Error(`Graph retry limit reached with status ${response.status}`);
      const retryAfter = response.headers.get("Retry-After");
      const seconds = retryAfter && /^\d+$/.test(retryAfter) ? Number(retryAfter) : 2 ** attempt;
      await sleep(Math.min(seconds * 1000, 60_000));
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
