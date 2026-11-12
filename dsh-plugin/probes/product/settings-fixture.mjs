// Test-only composition. Uses public stock APIs; never patches a host implementation.
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
export const inject = [
  "llm",
  "agents",
  "tools",
  "connection",
  "settings",
  "pluginManager",
];
export async function apply(ctx) {
  const require = createRequire(
    resolve(process.env.BB_PROBE_RUNTIME, "package.json"),
  );
  const { LlmAdapter } = await import(
    pathToFileURL(require.resolve("@deepseek-ai/dsh-llm"))
  );
  let calls = 0,
    failModel = false;
  class Model extends LlmAdapter {
    async resolveModel(provider, id) {
      return {
        provider,
        id,
        name: "SETTINGS TEST DOUBLE",
        inputModalities: ["text"],
        context: { contextWindow: 8192 },
      };
    }
    async *stream() {
      calls++;
      if (failModel) throw new Error("synthetic unknown provider outcome");
      yield { type: "finish", reason: { kind: "stop" } };
    }
  }
  ctx.effect(() => ctx.llm.registerAdapter(["bb-settings-test"], new Model()));
  const agentOptions = { provider: "bb-settings-test", model: "deterministic" };
  let handle;
  try {
    handle = await ctx.agents.resume({
      resumeSessionId: "settings-fixture",
      agentOptions,
    });
  } catch {
    handle = await ctx.agents.create({
      sessionId: "settings-fixture",
      agentOptions,
    });
  }
  ctx.effect(() => () => handle.dispose());
  if (process.env.BB_PROBE_STATUS === "1") {
    const replacement = await ctx.agents.create({
      sessionId: "settings-replacement",
      agentOptions,
    });
    ctx.effect(() => () => replacement.dispose());
    ctx.effect(() =>
      ctx.connection.fetch.register({
        path: "/api/bb-settings-test/unknown",
        methods: ["POST"],
        requestBody: "buffered",
        fetch: async () => {
          failModel = true;
          return Response.json({ enabled: true });
        },
      }),
    );
  }
  ctx.effect(() =>
    ctx.connection.fetch.register({
      path: "/api/bb-settings-test/probe",
      methods: ["GET"],
      requestBody: "buffered",
      fetch: async () => {
        let bridge;
        if (ctx.tools.schemas().some((t) => t.name === "bb_bridge_status")) {
          const result = await ctx.tools.execute({
            name: "bb_bridge_status",
            arguments: {},
            callId: "settings-observer",
            agent: handle.agent,
            signal: new AbortController().signal,
          });
          bridge = result.value;
        }
        const form = ctx.settings.describe().find((x) => x.ns === "bb-bridge");
        return Response.json({
          installed: (await ctx.pluginManager.listBundles()).some(
            (b) => b.name === "@bb/dsh-bridge" && b.installed,
          ),
          calls,
          mcpTools: ctx.tools
            .schemas()
            .filter((t) => t.name.startsWith("mcp__bb__")).length,
          bridge,
          form: form ? { revision: form.revision, value: form.value } : null,
          nativeInputs: handle.agent.session
            .snapshotEvents()
            .filter(
              (e) => e.type === "user/message" && e.data.id.startsWith("bb-"),
            ).length,
          titleRequests: handle.agent.session
            .snapshotEvents()
            .filter((e) => e.type === "session/title-llm-request").length,
          turns: handle.agent.session
            .snapshotEvents()
            .filter((e) => e.type === "turn/end").length,
        });
      },
    }),
  );
  ctx.effect(() =>
    ctx.connection.fetch.register({
      path: "/api/bb-settings-test/invalid",
      methods: ["POST"],
      requestBody: "buffered",
      fetch: async () => {
        const before = ctx.settings
          .describe()
          .find((x) => x.ns === "bb-bridge");
        const rejected = [];
        for (const patch of [
          { clientUrl: "https://example.com" },
          { clientUrl: "http://127.0.0.1:0" },
          { clientUrl: "http://127.0.0.1:65536" },
          { clientUrl: "http://user:secret@127.0.0.1:9187" },
          { targetSession: "bad session" },
          { peerAccount: "1234" },
          { pollMs: 249 },
          { pollMs: 30001 },
          { pollMs: 250.5 },
        ]) {
          let denied = false;
          try {
            await ctx.settings.update("bb-bridge", patch, before.revision);
          } catch {
            denied = true;
          }
          rejected.push(denied);
        }
        const after = ctx.settings.describe().find((x) => x.ns === "bb-bridge");
        return Response.json({
          rejected,
          unchanged:
            JSON.stringify(before.value) === JSON.stringify(after.value) &&
            before.revision === after.revision,
        });
      },
    }),
  );
}
