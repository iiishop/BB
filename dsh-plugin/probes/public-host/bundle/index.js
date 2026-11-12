// Disposable capability fixture, never a production BB bridge.
import z from '@deepseek-ai/schemastery';
export const inject = ['tools', 'probeWitness'];
export const Config = z.object({ label: z.string().default('initial').volatile() });
export function apply(ctx, config) {
  const witness = ctx.probeWitness;
  witness.mounts++;
  ctx.effect(() => ctx.tools.register({
    name: 'bb_probe_state', description: 'Synthetic lifecycle witness',
    parameters: { type: 'object', properties: {} },
    output: { schema: { type: 'string' }, render: (_, value) => [{ type: 'text', text: value }] },
    execute: async () => config.label.get(),
  }));
  ctx.on('loader/volatile-update', () => { witness.updates++; });
  ctx.effect(() => {
    witness.read = () => config.label.get();
    return () => { witness.disposals++; witness.read = undefined; };
  });
}
