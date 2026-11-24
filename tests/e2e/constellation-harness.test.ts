import { afterEach, describe, expect, test } from "bun:test";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const CXN_BIN = resolve(import.meta.dirname, "../../zig-out/bin/cxn");
const TIMEOUT = 30_000;

const ALLOWED_PUBLIC_RESPONSE_FIELDS = new Set([
  "model",
  "stream",
  "tools",
  "tool_choice",
  "user",
  "prompt_cache_key",
  "prompt_cache_retention",
  "prompt_cache_options",
  "parallel_tool_calls",
  "temperature",
  "input",
  "instructions",
  "reasoning",
  "max_output_tokens",
  "store",
  "include",
]);

interface RecordedRequest {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: Record<string, unknown> | null;
}

interface StubTurn {
  headers?: Record<string, string>;
  sse: string;
}

function responsesSse(events: Array<{ type: string; [key: string]: unknown }>): string {
  return (
    events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("") +
    "data: [DONE]\n\n"
  );
}

function textTurnSse(
  responseId: string,
  text: string,
  reasoning?: string,
): string {
  const events: Array<{ type: string; [key: string]: unknown }> = [
    { type: "response.created", response: { id: responseId, status: "in_progress" } },
  ];
  if (reasoning) {
    events.push({ type: "response.reasoning_summary_text.delta", delta: reasoning });
  }
  events.push(
    { type: "response.output_text.delta", delta: text },
    {
      type: "response.completed",
      response: {
        id: responseId,
        status: "completed",
        usage: {
          input_tokens: 120,
          output_tokens: 35,
          input_tokens_details: { cached_tokens: 20 },
          output_tokens_details: { reasoning_tokens: reasoning ? 10 : 0 },
        },
      },
    },
  );
  return responsesSse(events);
}

function toolCallTurnSse(
  responseId: string,
  callId: string,
  name: string,
  args: Record<string, unknown>,
): string {
  const argumentsJson = JSON.stringify(args);
  return responsesSse([
    { type: "response.created", response: { id: responseId, status: "in_progress" } },
    {
      type: "response.output_item.added",
      output_index: 0,
      item: {
        id: `fc_${callId}`,
        type: "function_call",
        call_id: callId,
        name,
        arguments: "",
      },
    },
    {
      type: "response.function_call_arguments.delta",
      output_index: 0,
      call_id: callId,
      delta: argumentsJson,
    },
    {
      type: "response.output_item.done",
      output_index: 0,
      item: {
        id: `fc_${callId}`,
        type: "function_call",
        call_id: callId,
        name,
        arguments: argumentsJson,
      },
    },
    {
      type: "response.completed",
      response: {
        id: responseId,
        status: "completed",
        usage: {
          input_tokens: 90,
          output_tokens: 24,
        },
      },
    },
  ]);
}

function startStubConstellationRouter(options: {
  models?: Array<Record<string, unknown>>;
  modelsHeaders?: Record<string, string>;
  turns: StubTurn[];
  expectedAuth?: string | null;
}) {
  const requests: RecordedRequest[] = [];
  let turnIndex = 0;
  const models = options.models ?? [
    {
      id: "constellation/auto",
      object: "model",
      owned_by: "constellation",
    },
    {
      id: "constellation/smart",
      object: "model",
      owned_by: "constellation",
    },
    {
      id: "constellation/efficient",
      object: "model",
      owned_by: "constellation",
    },
    {
      id: "openai/gpt-5.4",
      object: "model",
      owned_by: "codex",
      capabilities: ["chat", "tools", "vision"],
      context_window: 272000,
      max_completion_tokens: 32768,
      reasoning_efforts: [{ value: "low" }, { value: "medium" }, { value: "high" }],
    },
    {
      id: "anthropic/claude-sonnet-4.6",
      object: "model",
      owned_by: "claude",
      capabilities: ["chat", "tools"],
      context_window: 200000,
      reasoning_efforts: [{ value: "medium" }, { value: "high" }],
    },
  ];

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const headers: Record<string, string> = {};
      req.headers.forEach((value, key) => {
        headers[key.toLowerCase()] = value;
      });
      const text = req.method === "POST" ? await req.text() : "";
      const body = text ? (JSON.parse(text) as Record<string, unknown>) : null;
      requests.push({ method: req.method, path: url.pathname, headers, body });

      if (options.expectedAuth !== undefined) {
        if (options.expectedAuth === null) {
          if (headers.authorization) {
            return new Response(JSON.stringify({ error: { message: "unexpected auth" } }), {
              status: 400,
              headers: { "content-type": "application/json" },
            });
          }
        } else if (headers.authorization !== options.expectedAuth) {
          return new Response(JSON.stringify({ error: { message: "unauthorized" } }), {
            status: 401,
            headers: { "content-type": "application/json" },
          });
        }
      }

      if (req.method === "GET" && url.pathname === "/api/v1/models") {
        return new Response(JSON.stringify({ object: "list", data: models }), {
          status: 200,
          headers: {
            "content-type": "application/json",
            ...(options.modelsHeaders ?? {}),
          },
        });
      }

      if (req.method === "POST" && url.pathname === "/api/v1/responses") {
        const turn = options.turns[turnIndex];
        turnIndex += 1;
        if (!turn) {
          return new Response(JSON.stringify({ error: { message: "no stub turn remaining" } }), {
            status: 500,
            headers: { "content-type": "application/json" },
          });
        }
        return new Response(turn.sse, {
          status: 200,
          headers: {
            "content-type": "text/event-stream",
            "cache-control": "no-store",
            ...(turn.headers ?? {}),
          },
        });
      }

      return new Response(JSON.stringify({ error: { message: `unexpected ${req.method} ${url.pathname}` } }), {
        status: 404,
        headers: { "content-type": "application/json" },
      });
    },
  });

  return {
    baseUrl: `http://127.0.0.1:${server.port}/api/v1`,
    requests,
    stop: () => server.stop(true),
  };
}

function cleanEnv(overrides: Record<string, string | undefined>): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    if (
      key.startsWith("AI_GATEWAY_") ||
      key.startsWith("VERCEL_") ||
      key.startsWith("FX_") ||
      key.startsWith("CXN_") ||
      key.startsWith("CONSTELLATION_")
    ) {
      continue;
    }
    env[key] = value;
  }
  env.FX_AUTO_UPGRADE = "0";
  env.FX_SOUND = "0";
  env.FX_SKIP_ONBOARDING = "1";
  env.NO_COLOR = "1";
  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) {
      delete env[key];
    } else {
      env[key] = value;
    }
  }
  return env;
}

function runCxn(
  args: string[],
  options: { cwd: string; env: Record<string, string> },
): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolvePromise, reject) => {
    const child = nodeSpawn(CXN_BIN, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (code) => resolvePromise({ code, stdout, stderr }));
  });
}

function assertPublicRouterAllowlist(
  body: Record<string, unknown>,
  options: { allowConstellation?: boolean } = {},
): void {
  for (const key of Object.keys(body)) {
    if (options.allowConstellation && key === "constellation") continue;
    expect(ALLOWED_PUBLIC_RESPONSE_FIELDS.has(key)).toBe(true);
  }
  if (!options.allowConstellation) {
    expect(body).not.toHaveProperty("constellation");
  }
  expect(body).not.toHaveProperty("text");
  expect(body).not.toHaveProperty("service_tier");
  expect(body).not.toHaveProperty("previous_response_id");
  expect(body).not.toHaveProperty("conversation");
  expect(body).not.toHaveProperty("workspace_id");
  expect(body).not.toHaveProperty("workspaceId");
}

class AcpClient {
  private proc: ChildProcess;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  public notifications: Array<{ method: string; params: any }> = [];
  public stderr = "";

  constructor(cwd: string, env: Record<string, string>) {
    this.proc = nodeSpawn(CXN_BIN, ["acp"], {
      cwd,
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc.stderr?.on("data", (chunk: Buffer) => {
      this.stderr += chunk.toString("utf8");
    });
    this.proc.stdout?.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString("utf8");
      while (true) {
        const newline = this.buffer.indexOf("\n");
        if (newline < 0) break;
        const line = this.buffer.slice(0, newline).trim();
        this.buffer = this.buffer.slice(newline + 1);
        if (!line) continue;
        const msg = JSON.parse(line);
        if (msg.id !== undefined && this.pending.has(msg.id)) {
          const waiter = this.pending.get(msg.id)!;
          this.pending.delete(msg.id);
          waiter.resolve(msg);
        } else if (msg.method) {
          this.notifications.push({ method: msg.method, params: msg.params });
        }
      }
    });
    this.proc.on("exit", (code) => {
      for (const waiter of this.pending.values()) {
        waiter.reject(new Error(`cxn acp exited early with code ${code}; stderr=${this.stderr}`));
      }
      this.pending.clear();
    });
  }

  request(method: string, params: Record<string, unknown> = {}): Promise<any> {
    const id = this.nextId++;
    const payload = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    return new Promise((resolvePromise, reject) => {
      this.pending.set(id, { resolve: resolvePromise, reject });
      this.proc.stdin!.write(payload);
    });
  }

  async close(): Promise<number | null> {
    if (this.proc.exitCode !== null) return this.proc.exitCode;
    this.proc.stdin?.end();
    return new Promise((resolvePromise) => {
      const timer = setTimeout(() => {
        this.proc.kill("SIGKILL");
      }, 5_000);
      this.proc.once("exit", (code) => {
        clearTimeout(timer);
        resolvePromise(code);
      });
    });
  }
}

const cleanupDirs: string[] = [];
const cleanupRouters: Array<() => void> = [];
const cleanupClients: AcpClient[] = [];

function makeTempEnv(): { homeDir: string; workDir: string } {
  const root = mkdtempSync(join(tmpdir(), "cxn-harness-"));
  cleanupDirs.push(root);
  const homeDir = join(root, "home");
  const workDir = join(root, "work");
  mkdirSync(join(homeDir, ".fx"), { recursive: true });
  mkdirSync(workDir, { recursive: true });
  // Seed stale upstream fx provider settings to prove cxn ignores them.
  writeFileSync(
    join(homeDir, ".fx", "settings.json"),
    JSON.stringify({
      provider: "codex",
      model: "moonshotai/kimi-k3",
      models: {
        gateway: "moonshotai/kimi-k3",
        codex: "gpt-5.4",
      },
    }),
  );
  return { homeDir, workDir };
}

afterEach(async () => {
  while (cleanupClients.length > 0) {
    await cleanupClients.pop()!.close();
  }
  while (cleanupRouters.length > 0) {
    cleanupRouters.pop()!();
  }
  while (cleanupDirs.length > 0) {
    rmSync(cleanupDirs.pop()!, { recursive: true, force: true });
  }
});

describe("cxn Constellation-exclusive harness", () => {
  test("cxn activates Constellation defaults, ignores stale upstream settings, and reports Constellation missing-key guidance", async () => {
    const { homeDir, workDir } = makeTempEnv();

    const ver = await runCxn(["--version"], {
      cwd: workDir,
      env: cleanEnv({ HOME: homeDir }),
    });
    expect(ver.code).toBe(0);
    expect(ver.stderr).toBe("");
    expect(ver.stdout.trim().length).toBeGreaterThan(0);

    const status = await runCxn(["status", "--json"], {
      cwd: workDir,
      env: cleanEnv({ HOME: homeDir, CXN_API_KEY: "test-cxn-key" }),
    });
    expect(status.code).toBe(0);
    expect(status.stderr).toBe("");
    const parsedStatus = JSON.parse(status.stdout.trim());
    expect(parsedStatus.model).toBe("constellation/auto");
    expect(parsedStatus.auth).toBe("CXN_API_KEY");

    const doctor = await runCxn(["doctor", "--json"], {
      cwd: workDir,
      env: cleanEnv({ HOME: homeDir, CXN_API_KEY: "test-cxn-key" }),
    });
    expect(doctor.code).toBe(0);
    expect(doctor.stderr).toBe("");
    const parsedDoctor = JSON.parse(doctor.stdout.trim());
    expect(parsedDoctor.model).toBe("constellation/auto");
    expect(parsedDoctor.model_source).toBeUndefined();
    expect(parsedDoctor.auth).toBe("CXN_API_KEY");

    const missingKey = await runCxn(["ask", "hello"], {
      cwd: workDir,
      env: cleanEnv({ HOME: homeDir }),
    });
    expect(missingKey.code).not.toBe(0);
    expect(missingKey.stderr).toContain("CXN_API_KEY");
    expect(missingKey.stderr).not.toContain("Vercel AI Gateway");
  }, TIMEOUT);

  test("cxn models --json discovers dynamic models from Constellation Router", async () => {
    const { homeDir, workDir } = makeTempEnv();
    const router = startStubConstellationRouter({
      expectedAuth: "Bearer test-cxn-key",
      turns: [],
    });
    cleanupRouters.push(router.stop);

    const result = await runCxn(["models", "--json"], {
      cwd: workDir,
      env: cleanEnv({
        HOME: homeDir,
        CXN_ROUTER_URL: router.baseUrl,
        CXN_API_KEY: "test-cxn-key",
      }),
    });
    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
    const parsed = JSON.parse(result.stdout.trim());
    expect(parsed.ids).toEqual([
      "constellation/auto",
      "constellation/smart",
      "constellation/efficient",
      "openai/gpt-5.4",
      "anthropic/claude-sonnet-4.6",
    ]);
    expect(router.requests).toHaveLength(1);
    expect(router.requests[0].path).toBe("/api/v1/models");
    expect(router.requests[0].headers["x-constellation-client"]).toBe("cxn");
  }, TIMEOUT);

  test("cxn ask --json executes a multi-step tool loop over Constellation Responses API with strict allowlisted payloads", async () => {
    const { homeDir, workDir } = makeTempEnv();
    writeFileSync(join(workDir, "target.txt"), "constellation-verified-content\n");

    const router = startStubConstellationRouter({
      expectedAuth: "Bearer test-cxn-key",
      turns: [
        {
          headers: {
            "X-Constellation-Route-Model": "openai/gpt-5.4-mini",
            "X-Constellation-Route-Path": "constellation/auto",
            "X-Constellation-Route-Label": "efficient",
          },
          sse: toolCallTurnSse("resp_step_1", "call_read_1", "read_file", {
            path: "target.txt",
          }),
        },
        {
          headers: {
            "X-Constellation-Route-Model": "openai/gpt-5.4-mini",
            "X-Constellation-Route-Path": "constellation/auto",
          },
          sse: textTurnSse("resp_step_2", "Verified: constellation-verified-content"),
        },
      ],
    });
    cleanupRouters.push(router.stop);

    const result = await runCxn(["ask", "--json", "Read target.txt and report its contents."], {
      cwd: workDir,
      env: cleanEnv({
        HOME: homeDir,
        CXN_ROUTER_URL: router.baseUrl,
        CXN_API_KEY: "test-cxn-key",
      }),
    });
    expect(result.code).toBe(0);
    expect(result.stderr).not.toContain("panic");
    expect(result.stderr).not.toContain("Vercel");
    const parsed = JSON.parse(result.stdout.trim());
    expect(parsed.model).toBe("constellation/auto");
    expect(parsed.output).toContain("constellation-verified-content");
    expect(parsed.steps).toBeGreaterThanOrEqual(1);
    expect(parsed.tool_calls.some((t: any) => t.name === "read_file" && t.status === "success")).toBe(true);

    const responseRequests = router.requests.filter((r) => r.path === "/api/v1/responses");
    expect(responseRequests).toHaveLength(2);
    for (const req of responseRequests) {
      expect(req.body).not.toBeNull();
      assertPublicRouterAllowlist(req.body!);
      expect(req.body!.model).toBe("constellation/auto");
      expect(req.body!.store).toBe(false);
      expect(req.body!.stream).toBe(true);
      expect(req.headers["x-constellation-client"]).toBe("cxn");
    }
    const secondInput = responseRequests[1].body!.input as Array<Record<string, unknown>>;
    expect(
      secondInput.some(
        (item) =>
          item.type === "function_call_output" &&
          typeof item.output === "string" &&
          item.output.includes("constellation-verified-content"),
      ),
    ).toBe(true);
  }, TIMEOUT);

  test("cxn acp drives full T3 Code lifecycle with dynamic models, effort, tool loop, route telemetry, and session reload", async () => {
    const { homeDir, workDir } = makeTempEnv();
    writeFileSync(join(workDir, "hello.txt"), "acp-file-secret-42\n");

    const router = startStubConstellationRouter({
      expectedAuth: "Bearer acp-cxn-key",
      turns: [
        {
          headers: {
            "X-Constellation-Route-Model": "anthropic/claude-sonnet-4.6",
            "X-Constellation-Route-Path": "constellation/smart",
            "X-Constellation-Route-Label": "smart",
            "X-Constellation-Route-Effort": "high",
          },
          sse: toolCallTurnSse("resp_acp_1", "call_acp_read", "read_file", {
            path: "hello.txt",
          }),
        },
        {
          headers: {
            "X-Constellation-Route-Model": "anthropic/claude-sonnet-4.6",
            "X-Constellation-Route-Path": "constellation/smart",
            "X-Constellation-Route-Label": "smart",
            "X-Constellation-Route-Effort": "high",
          },
          sse: textTurnSse("resp_acp_2", "The file contains acp-file-secret-42.", "Checked hello.txt."),
        },
      ],
    });
    cleanupRouters.push(router.stop);

    const client = new AcpClient(
      workDir,
      cleanEnv({
        HOME: homeDir,
        CXN_ROUTER_URL: router.baseUrl,
        CXN_API_KEY: "acp-cxn-key",
      }),
    );
    cleanupClients.push(client);

    const initResp = await client.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {},
    });
    expect(initResp.error).toBeUndefined();
    expect(initResp.result.agentInfo.name).toBe("cxn");
    expect(initResp.result.agentInfo.title).toBe("cxn");
    expect(initResp.result.agentCapabilities.loadSession).toBe(true);

    const newResp = await client.request("session/new", { cwd: workDir, mcpServers: [] });
    expect(newResp.error).toBeUndefined();
    const sessionId = newResp.result.sessionId as string;
    expect(sessionId.length).toBeGreaterThan(0);

    const providerOpt = newResp.result.configOptions.find((opt: any) => opt.id === "provider");
    expect(providerOpt.currentValue).toBe("constellation");
    expect(providerOpt.options).toEqual([{ value: "constellation", name: "Constellation Router" }]);

    const modelOpt = newResp.result.configOptions.find((opt: any) => opt.id === "model");
    expect(modelOpt.currentValue).toBe("constellation/auto");
    expect(modelOpt.options.map((o: any) => o.value)).toContain("constellation/smart");
    expect(modelOpt.options.map((o: any) => o.value)).toContain("openai/gpt-5.4");

    const badProvider = await client.request("session/set_config_option", {
      sessionId,
      configId: "provider",
      value: "codex",
    });
    expect(badProvider.error).toBeDefined();

    const setModel = await client.request("session/set_config_option", {
      sessionId,
      configId: "model",
      value: "constellation/smart",
    });
    expect(setModel.error).toBeUndefined();
    expect(setModel.result.configOptions.find((o: any) => o.id === "model").currentValue).toBe(
      "constellation/smart",
    );

    const setEffort = await client.request("session/set_config_option", {
      sessionId,
      configId: "effort",
      value: "high",
    });
    expect(setEffort.error).toBeUndefined();

    const promptResp = await client.request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "Read hello.txt and tell me its value." }],
    });
    expect(promptResp.error).toBeUndefined();
    expect(promptResp.result.stopReason).toBe("end_turn");

    const updates = client.notifications
      .filter((n) => n.method === "session/update")
      .map((n) => n.params.update);

    const messageText = updates
      .filter((u) => u.sessionUpdate === "agent_message_chunk")
      .map((u) => u.content?.text ?? "")
      .join("");
    expect(messageText).toContain("acp-file-secret-42");

    expect(updates.some((u) => u.sessionUpdate === "tool_call" && u.name === "read_file")).toBe(true);
    expect(updates.some((u) => u.sessionUpdate === "usage_update" && u.size > 0)).toBe(true);

    const infoWithMeta = updates.find(
      (u) => u.sessionUpdate === "session_info_update" && u._meta?.constellation,
    );
    expect(infoWithMeta).toBeDefined();
    expect(infoWithMeta._meta.constellation.routeModel).toBe("anthropic/claude-sonnet-4.6");
    expect(infoWithMeta._meta.constellation.routePath).toBe("constellation/smart");
    expect(infoWithMeta._meta.constellation.routeLabel).toBe("smart");
    expect(infoWithMeta._meta.constellation.routeEffort).toBe("high");

    const responseRequests = router.requests.filter((r) => r.path === "/api/v1/responses");
    expect(responseRequests).toHaveLength(2);
    for (const req of responseRequests) {
      assertPublicRouterAllowlist(req.body!);
      expect(req.body!.model).toBe("constellation/smart");
      expect((req.body!.reasoning as Record<string, unknown>).effort).toBe("high");
      expect(req.headers["session-id"]).toBe(sessionId);
    }

    const loadResp = await client.request("session/load", {
      sessionId,
      cwd: workDir,
      mcpServers: [],
    });
    expect(loadResp.error).toBeUndefined();

    const exitCode = await client.close();
    expect(exitCode).toBe(0);
    expect(client.stderr).toBe("");
  }, TIMEOUT);

  test("cxn auto-mode permission reviewer routes exclusively to Constellation Router and supports host-managed auth", async () => {
    const { homeDir, workDir } = makeTempEnv();
    writeFileSync(join(workDir, "temp.txt"), "delete-me\n");

    const router = startStubConstellationRouter({
      expectedAuth: null,
      turns: [
        {
          sse: toolCallTurnSse("resp_auto_1", "call_shell_1", "shell", {
            request: {
              action: "run",
              command: "rm -f temp.txt",
              yield_time_ms: 5000,
              timeout_ms: 30000,
            },
          }),
        },
        // Second POST /responses is the Constellation auto permission reviewer call.
        {
          sse: toolCallTurnSse("resp_review_1", "call_reviewer", "submit_permission_review", {
            decision: "clear",
            reason: "User explicitly asked to remove temp.txt.",
          }),
        },
        {
          sse: textTurnSse("resp_auto_2", "Removed temp.txt cleanly."),
        },
      ],
    });
    cleanupRouters.push(router.stop);

    const result = await runCxn(
      ["ask", "--auto", "--json", "Delete temp.txt using shell."],
      {
        cwd: workDir,
        env: cleanEnv({
          HOME: homeDir,
          FX_AUTH_MODE: "host-managed",
          CXN_ROUTER_URL: router.baseUrl,
        }),
      },
    );
    expect(result.code).toBe(0);
    expect(result.stderr).not.toContain("panic");
    expect(result.stderr).not.toContain("Vercel");
    const parsed = JSON.parse(result.stdout.trim());
    expect(parsed.output).toContain("Removed temp.txt cleanly.");

    const responseRequests = router.requests.filter((r) => r.path === "/api/v1/responses");
    expect(responseRequests.length).toBeGreaterThanOrEqual(2);
    for (const req of responseRequests) {
      assertPublicRouterAllowlist(req.body!);
      expect(req.headers.authorization).toBeUndefined();
    }
    const reviewReq = responseRequests.find((r) => r.body?.tool_choice === "required");
    expect(reviewReq).toBeDefined();
    expect(reviewReq!.body!.model).toBe("constellation/auto");
  }, TIMEOUT);

  test("cxn T3 Code provider-fx compatibility isolates legacy backend probes and ignores FX_MODEL=default", async () => {
    const { homeDir, workDir } = makeTempEnv();

    for (const legacyBackend of ["codex", "grok"]) {
      const probed = await runCxn(["status", "--json"], {
        cwd: workDir,
        env: cleanEnv({
          HOME: homeDir,
          CXN_API_KEY: "test-cxn-key",
          FX_PROVIDER: legacyBackend,
          FX_MODEL: "default",
        }),
      });
      expect(probed.code).toBe(0);
      expect(probed.stderr).toBe("");
      const parsed = JSON.parse(probed.stdout.trim());
      expect(parsed.auth).toBe("missing");
    }

    const gwStatus = await runCxn(["status", "--json"], {
      cwd: workDir,
      env: cleanEnv({
        HOME: homeDir,
        CXN_API_KEY: "test-cxn-key",
        FX_PROVIDER: "gateway",
        FX_MODEL: "default",
      }),
    });
    expect(gwStatus.code).toBe(0);
    expect(gwStatus.stderr).toBe("");
    const parsedGw = JSON.parse(gwStatus.stdout.trim());
    expect(parsedGw.auth).toBe("CXN_API_KEY");
    expect(parsedGw.model).toBe("constellation/auto");

    const gwDoctor = await runCxn(["doctor", "--json"], {
      cwd: workDir,
      env: cleanEnv({
        HOME: homeDir,
        CXN_API_KEY: "test-cxn-key",
        FX_PROVIDER: "gateway",
        FX_MODEL: "default",
      }),
    });
    expect(gwDoctor.code).toBe(0);
    const parsedDoc = JSON.parse(gwDoctor.stdout.trim());
    expect(parsedDoc.auth).toBe("CXN_API_KEY");
    expect(parsedDoc.model).toBe("constellation/auto");
  }, TIMEOUT);

  test("cxn Phase 2 harness profiles emit signaling headers while remaining body-compatible with legacy routers", async () => {
    const { homeDir, workDir } = makeTempEnv();
    const router = startStubConstellationRouter({
      expectedAuth: "Bearer phase2-key",
      turns: [
        {
          headers: {
            "X-Constellation-Route-Model": "openai/gpt-5.4-mini",
            "X-Constellation-Route-Path": "constellation/efficient",
          },
          sse: textTurnSse("resp_econ_1", "Renamed foo to bar."),
        },
      ],
    });
    cleanupRouters.push(router.stop);

    const invalid = await runCxn(["--profile", "does-not-exist", "status", "--json"], {
      cwd: workDir,
      env: cleanEnv({ HOME: homeDir, CXN_API_KEY: "phase2-key" }),
    });
    expect(invalid.code).not.toBe(0);
    expect(invalid.stderr).toContain("unknown --profile");

    const res = await runCxn(
      ["--profile", "economy", "ask", "--no-save", "--json", "Rename foo to bar in example.txt"],
      {
        cwd: workDir,
        env: cleanEnv({
          HOME: homeDir,
          CXN_ROUTER_URL: router.baseUrl,
          CXN_API_KEY: "phase2-key",
        }),
      },
    );
    expect(res.code).toBe(0);
    expect(res.stderr).not.toContain("panic");
    const parsed = JSON.parse(res.stdout.trim());
    expect(parsed.model).toBe("constellation/efficient");
    expect(parsed.output).toContain("Renamed foo to bar.");

    const reqs = router.requests.filter((r) => r.path === "/api/v1/responses");
    expect(reqs).toHaveLength(1);
    assertPublicRouterAllowlist(reqs[0].body!, { allowConstellation: false });
    expect(reqs[0].body!.model).toBe("constellation/efficient");
    expect(reqs[0].headers["x-constellation-profile"]).toBe("economy");
    expect(reqs[0].headers["x-constellation-signal-version"]).toBe("1");
    expect(reqs[0].headers["x-constellation-phase"]).toBe("initial_plan");
    expect(reqs[0].headers["x-constellation-task-class"]).toBe("mechanical_edit");
  }, TIMEOUT);

  test("cxn Phase 2 capability-gated signaling-v1 body envelope, ACP profile switching, gateway: slug normalization, and telemetry", async () => {
    const { homeDir, workDir } = makeTempEnv();
    writeFileSync(join(workDir, "spec.txt"), "phase2-signaling-ok\n");

    const router = startStubConstellationRouter({
      expectedAuth: "Bearer sig-v1-key",
      modelsHeaders: {
        "X-Constellation-Capabilities": "signaling-v1",
      },
      turns: [
        {
          headers: {
            "X-Constellation-Route-Model": "anthropic/claude-sonnet-4.6",
            "X-Constellation-Route-Path": "constellation/smart",
            "X-Constellation-Seat-Pressure": "tight",
            "X-Constellation-Context-Window": "272000",
            "X-Constellation-Signal-Accepted": "v1",
          },
          sse: toolCallTurnSse("resp_sig_1", "call_sig_read", "read_file", {
            path: "spec.txt",
          }),
        },
        {
          headers: {
            "X-Constellation-Route-Model": "anthropic/claude-sonnet-4.6",
            "X-Constellation-Route-Path": "constellation/smart",
            "X-Constellation-Seat-Pressure": "tight",
            "X-Constellation-Context-Window": "272000",
            "X-Constellation-Signal-Accepted": "v1",
          },
          sse: textTurnSse("resp_sig_2", "Verified spec: phase2-signaling-ok"),
        },
        {
          headers: {
            "X-Constellation-Route-Model": "openai/gpt-5.4",
            "X-Constellation-Signal-Accepted": "v1",
          },
          sse: textTurnSse("resp_sig_3", "Pinned model turn complete."),
        },
      ],
    });
    cleanupRouters.push(router.stop);

    const client = new AcpClient(
      workDir,
      cleanEnv({
        HOME: homeDir,
        CXN_ROUTER_URL: router.baseUrl,
        CXN_API_KEY: "sig-v1-key",
      }),
    );
    cleanupClients.push(client);

    const initResp = await client.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {},
    });
    expect(initResp.error).toBeUndefined();

    const newResp = await client.request("session/new", { cwd: workDir, mcpServers: [] });
    expect(newResp.error).toBeUndefined();
    const sessionId = newResp.result.sessionId as string;

    // Generic ACP hosts (such as T3 Code acpRegistry) select the first
    // category="model" option; verify `model` precedes `provider`.
    const firstModelCat = newResp.result.configOptions.find((o: any) => o.category === "model");
    expect(firstModelCat.id).toBe("model");

    const effortOpt = newResp.result.configOptions.find((o: any) => o.id === "effort");
    expect(effortOpt).toBeDefined();
    expect(effortOpt.category).toBe("thought_level");
    expect(effortOpt.options.map((o: any) => o.value)).toContain("medium");

    const profileOpt = newResp.result.configOptions.find((o: any) => o.id === "profile");
    expect(profileOpt).toBeDefined();
    expect(profileOpt.category).toBe("model_config");
    expect(profileOpt.currentValue).toBe("balanced");
    expect(profileOpt.options.map((o: any) => o.value)).toEqual([
      "balanced",
      "economy",
      "deep",
      "pinned",
    ]);

    const setDeep = await client.request("session/set_config_option", {
      sessionId,
      configId: "profile",
      value: "deep",
    });
    expect(setDeep.error).toBeUndefined();
    expect(setDeep.result.configOptions.find((o: any) => o.id === "profile").currentValue).toBe("deep");
    expect(setDeep.result.configOptions.find((o: any) => o.id === "model").currentValue).toBe(
      "constellation/smart",
    );

    const prompt1 = await client.request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "Architect a security review of spec.txt after reading it." }],
    });
    expect(prompt1.error).toBeUndefined();
    expect(prompt1.result.stopReason).toBe("end_turn");

    const updates = client.notifications
      .filter((n) => n.method === "session/update")
      .map((n) => n.params.update);
    const infoMeta = updates.find(
      (u) => u.sessionUpdate === "session_info_update" && u._meta?.constellation?.signalAccepted === "v1",
    );
    expect(infoMeta).toBeDefined();
    expect(infoMeta._meta.constellation.seatPressure).toBe("tight");
    expect(infoMeta._meta.constellation.contextWindow).toBe("272000");
    expect(infoMeta._meta.constellation.profile).toBe("deep");
    expect(infoMeta._meta.constellation.phase).toBe("tool_continuation");

    const setGatewaySlug = await client.request("session/set_config_option", {
      sessionId,
      configId: "model",
      value: "gateway:openai/gpt-5.4",
    });
    expect(setGatewaySlug.error).toBeUndefined();
    expect(setGatewaySlug.result.configOptions.find((o: any) => o.id === "model").currentValue).toBe(
      "openai/gpt-5.4",
    );

    const prompt2 = await client.request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "Confirm readiness." }],
    });
    expect(prompt2.error).toBeUndefined();

    const responseRequests = router.requests.filter((r) => r.path === "/api/v1/responses");
    expect(responseRequests).toHaveLength(3);
    for (const req of responseRequests) {
      assertPublicRouterAllowlist(req.body!, { allowConstellation: true });
      expect(req.body!.constellation).toBeDefined();
      const sig = req.body!.constellation as Record<string, any>;
      expect(sig.signal_version).toBe(1);
      expect(sig.harness).toBe("cxn");
      expect(sig.profile).toBe("deep");
    }

    const sig1 = responseRequests[0].body!.constellation as Record<string, any>;
    expect(sig1.phase).toBe("initial_plan");
    expect(sig1.advisory.reasoning_need).toBe("high");
    expect((responseRequests[0].body!.reasoning as Record<string, any>).effort).toBe("high");

    const sig2 = responseRequests[1].body!.constellation as Record<string, any>;
    expect(sig2.phase).toBe("tool_continuation");
    expect(sig2.advisory.tool_calls_in_turn).toBeGreaterThanOrEqual(1);

    expect(responseRequests[2].body!.model).toBe("openai/gpt-5.4");

    const exitCode = await client.close();
    expect(exitCode).toBe(0);
    expect(client.stderr).toBe("");
  }, TIMEOUT);
});
