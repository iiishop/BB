// Isolated product-probe composition: no CLI home/profile overlays or credentials.
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile } from 'node:fs/promises';

export async function boot(packageRoot, storageRoot, observe = () => {}, modelHook = async () => {}) {
  const require = createRequire(resolve(packageRoot, 'package.json'));
  const load = async name => import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
  const { Context } = await load('cordis');
  const ctx = new Context();
  const fibers = [];
  const versions = {};
  const mount = async (name, config) => {
    const mod = await load(name);
    const meta = JSON.parse(await readFile(require.resolve(`@deepseek-ai/${name}/package.json`), 'utf8'));
    versions[name] = meta.version;
    if (name.startsWith('dsh-') && meta.version !== '0.2.1-rc.5') {
      throw new Error(`Unverified runtime version: ${name}@${meta.version}`);
    }
    fibers.push(await ctx.plugin(mod.default ?? mod, config));
    return mod;
  };
  const llm = await mount('dsh-llm');
  await mount('dsh-session');
  await mount('dsh-session-projection');
  await mount('dsh-system-prompt', { includeHarnessIdentity: false, includeRuntimeContext: false });
  await mount('dsh-tools');
  await mount('dsh-agent');
  await mount('dsh-session-persistence-jsonl', { root: resolve(storageRoot), compression: 'none' });
  await mount('dsh-agent-loop', { agents: [], maxParallelToolCalls: 1 });

  // Only the model is a deterministic double. Core Agent/Inbox/Session/JSONL are real.
  class DeterministicModel extends llm.LlmAdapter {
    async resolveModel(provider, model) {
      return { provider, id: model, name: 'DETERMINISTIC TEST DOUBLE', inputModalities: ['text'], context: { contextWindow: 8192 } };
    }
    async *stream(options) {
      observe('model.request', { ids: options.messages.map(message => message.id) });
      await modelHook(options);
      yield { type: 'block-start', index: 0, blockType: 'text' };
      yield { type: 'text-delta', index: 0, text: 'synthetic acknowledgment' };
      yield { type: 'block-end', index: 0, block: { type: 'text', text: 'synthetic acknowledgment' } };
      yield { type: 'finish', reason: { kind: 'stop' } };
    }
  }
  const unregister = ctx.llm.registerAdapter(['bb-probe'], new DeterministicModel());
  ctx.on('agent/error', ({ error }) => { observe('agent.error', { message: String(error) }); });
  ctx.on('session/event', (session, event) => observe('session.event', { sessionId: session.id, event }));
  const handles = [];
  return {
    ctx, versions,
    async open(sessionId, resume = false) {
      const options = { agentOptions: { provider: 'bb-probe', model: 'deterministic' } };
      const handle = resume
        ? await ctx.agents.resume({ ...options, resumeSessionId: sessionId })
        : await ctx.agents.create({ ...options, sessionId });
      handles.push(handle);
      return handle.agent;
    },
    async close() {
      for (const handle of handles.reverse()) await handle.dispose();
      unregister();
      for (const fiber of fibers.reverse()) await fiber.dispose();
    },
  };
}
