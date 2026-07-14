import http from "node:http";
import type { AddressInfo } from "node:net";
import { createApp, type AppDependencies } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import type { Config } from "../src/config.js";

export interface TestServer {
  baseUrl: string;
  close: () => Promise<void>;
}

export async function startTestServer(
  overrides: Partial<Config> = {},
  deps: Partial<Omit<AppDependencies, "config">> = {}
): Promise<
  TestServer & Pick<ReturnType<typeof createApp>, "taskEventBus" | "clientSessionStore">
> {
  const config: Config = { ...loadConfig({}), ...overrides };
  const built = createApp({ config, ...deps });
  const server = http.createServer(built.app);
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const { port } = server.address() as AddressInfo;

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    taskEventBus: built.taskEventBus,
    clientSessionStore: built.clientSessionStore,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

/** fetch's Response#json() is typed as Promise<unknown> under our tsconfig; tests want ad-hoc shapes. */
export async function readJson<T = any>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

export function authHeaders(token: string, extra: Record<string, string> = {}) {
  return {
    "content-type": "application/json",
    authorization: `Bearer ${token}`,
    ...extra,
  };
}

export interface MintedSession {
  sessionToken: string;
  hermesSessionId: string;
  expiresAt: string;
}

/** Calls the real POST /v1/session bootstrap route — exercises the same path a client would. */
export async function bootstrapSession(
  baseUrl: string,
  options: { bootstrapSecret?: string } = {}
): Promise<MintedSession> {
  const res = await fetch(`${baseUrl}/v1/session`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(options.bootstrapSecret ? { authorization: `Bearer ${options.bootstrapSecret}` } : {}),
    },
    body: JSON.stringify({}),
  });
  if (res.status !== 201) {
    throw new Error(`bootstrapSession failed with ${res.status}: ${await res.text()}`);
  }
  return readJson<MintedSession>(res);
}

/** Starts a server and immediately bootstraps one client session against it — the common case. */
export async function startAuthedTestServer(
  overrides: Partial<Config> = {},
  deps: Partial<Omit<AppDependencies, "config">> = {}
): Promise<TestServer & MintedSession & { authHeaders: (extra?: Record<string, string>) => Record<string, string> }> {
  const server = await startTestServer(overrides, deps);
  const session = await bootstrapSession(server.baseUrl, { bootstrapSecret: overrides.bootstrapSecret });
  return {
    ...server,
    ...session,
    authHeaders: (extra: Record<string, string> = {}) => authHeaders(session.sessionToken, extra),
  };
}
