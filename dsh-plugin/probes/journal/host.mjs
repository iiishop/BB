// Fixed installed host; only the model provider is a deterministic test double.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';

export async function boot(pkg, root, provider, observe, options = {}) {
  const require = createRequire(resolve(pkg, 'package.json'));
  const load = name => import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
  const { Context } = await load('cordis');
  const ctx = new Context();
  const mount = async (name, config) => {
    const mod = await load(name);
    await ctx.plugin(mod.default ?? mod, config);
    return mod;
  };
  const llm = await mount('dsh-llm');
  if (options.images) await mount('dsh-attachment-local', { dshHome: resolve(root, 'home') });
  await mount('dsh-session');
  await mount('dsh-session-projection');
  await mount('dsh-system-prompt', { includeHarnessIdentity: false, includeRuntimeContext: false });
  await mount('dsh-tools');
  await mount('dsh-agent');
  await mount('dsh-session-persistence-jsonl', { root: resolve(root, 'sessions'), compression: 'none' });
  await mount('dsh-agent-loop', { agents: [], maxParallelToolCalls: 1 });
  await mount('dsh-storage');
  await mount('dsh-storage-json', { root: resolve(root, 'journal') });
  const domainModule = await mount('dsh-storage-domain', { backend: 'json' });
  const domainRequire = createRequire(require.resolve('@deepseek-ai/dsh-storage-domain'));
  const { z } = await import(pathToFileURL(domainRequire.resolve('zod')));
  class Model extends llm.LlmAdapter {
    async resolveModel(provider, id) { return { provider, id, name: 'JOURNAL PROBE DOUBLE', inputModalities: options.images ? ['text', 'image'] : ['text'], context: { contextWindow: 8192 } }; }
    async *stream(options) { observe('provider', { ids: options.messages.map(m => m.id) }); yield* provider(options); }
  }
  const unregister = ctx.llm.registerAdapter(['journal-probe'], new Model());
  ctx.on('session/event', (session, event) => observe('event', { session: session.id, event }));
  ctx.on('agent/error', ({ error }) => observe('error', { message: String(error) }));
  const handles = [];
  return { ctx, load, z, domainModule,
    async open(id, resume = false) {
      const options = { agentOptions: { provider: 'journal-probe', model: 'deterministic' } };
      const handle = resume ? await ctx.agents.resume({ ...options, resumeSessionId: id }) : await ctx.agents.create({ ...options, sessionId: id });
      handles.push(handle);
      assert.equal(typeof handle.agent.bbDeliver, 'undefined');
      return handle.agent;
    },
    async close() { for (const handle of handles.reverse()) await handle.dispose(); unregister(); await ctx.fiber.dispose(); },
  };
}
