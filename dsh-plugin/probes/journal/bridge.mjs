// Experimental BB-owned metadata journal. No private APIs or synthetic Session events.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

export const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export const eventKey = event => digest([event.account, event.consumer, event.event_id]);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

export async function createJournal(runtime) {
  const { z, domainModule, ctx } = runtime;
  const binding = z.object({ account: z.string(), consumer: z.string(), generation: z.number().int(), revision: z.number().int() }).strict();
  const attempt = z.object({ id: z.string(), session: z.string(), state: z.enum(['prepared', 'claimed', 'dispatching', 'presented', 'retired', 'uncertain']),
    turn: z.number().int().optional(), request_digest: z.string().optional() }).strict();
  const row = z.object({ binding, event_id: z.string(), peer: z.string(), position: z.number().int().positive(),
    digest: z.string(), state: z.enum(['received', 'active', 'uncertain', 'completed']), attempts: z.array(attempt) }).strict();
  const operation = z.object({ binding, key: z.string(), operation_id: z.string(), args: z.record(z.string(), z.unknown()),
    digest: z.string(), state: z.enum(['planned', 'dispatching', 'uncertain', 'succeeded']), result: z.unknown().optional() }).strict();
  const spec = domainModule.defineDomain({ name: 'bb_attempt_probe', version: 1,
    tables: { events: domainModule.domainTable(row), operations: domainModule.domainTable(operation) } });
  const domain = await ctx.storageDomain.open(spec);
  const schemas = { events: row, operations: operation };
  return { domain, get: (table, key) => structuredClone(domain.table(table).get(key)),
    async put(table, key, value) { await domain.table(table).put(key, schemas[table].parse(value)); },
    async close() { await domain.close(); } };
}

export class JournalBridge {
  constructor(ctx, agent, journal, binding, client, checkpoint = async () => {}) {
    Object.assign(this, { ctx, agent, journal, binding, client, checkpoint });
    this.tail = Promise.resolve(); this.closed = false; this.active = new Map(); this.owned = new Set();
    this.observerTail = Promise.resolve(); this.recoveries = new Map(); this.observerErrors = [];
  }
  check(binding = this.binding) {
    assert.ok(!this.closed, 'bridge disposed');
    assert.ok(same(binding, this.binding) && same(binding, this.client.identity()), 'stale identity/binding');
  }
  serial(action) { const task = this.tail.then(action); this.tail = task.catch(() => {}); return task; }
  async flush() { assert.equal(await this.ctx.sessions.flush(this.agent.session), true); }
  async mount() {
    const self = this;
    this.fiber = await this.ctx.plugin({ name: 'bb-journal-probe', apply(ctx) {
      ctx.on('agent/pre-step', async (payload, next) => {
        if (payload.agent !== self.agent) return next();
        self.check();
        await self.serial(async () => {
          for (const message of payload.messages) {
            const key = self.ownedKey(message.id);
            if (!key) continue;
            const row = self.journal.get('events', key);
            const attempt = row.attempts.find(a => a.id === message.id);
            assert.equal(row.state, 'active');
            assert.ok(['prepared', 'claimed'].includes(attempt.state), 'cannot claim dispatched/retired input');
            attempt.state = 'claimed'; attempt.turn = payload.turn;
            await self.journal.put('events', key, row);
            self.active.set(payload.turn, key);
          }
        });
        await self.checkpoint('claimed', self);
        return next();
      });
      ctx.on('llm/stream', async function* (options, next) {
        if (options.sessionId !== self.agent.session.id) { yield* next(); return; }
        self.check();
        const current = [...self.active.entries()].at(-1);
        assert.ok(current, 'no owned active event');
        const [turn, key] = current;
        await self.serial(async () => {
          const row = self.journal.get('events', key);
          const attempt = row.attempts.findLast(a => a.turn === turn);
          assert.ok(['claimed', 'presented'].includes(attempt.state), 'uncertain dispatch must not retry');
          assert.ok(options.messages.some(m => m.id === attempt.id), 'attempt absent from model context');
          attempt.state = 'dispatching'; attempt.request_digest = digest(options.messages);
          await self.journal.put('events', key, row);
          await self.flush();
        });
        await self.checkpoint('dispatch-intent', self);
        let finish;
        try {
          for await (const chunk of next()) { if (chunk.type === 'finish') finish = chunk.reason.kind; yield chunk; }
          if (!['stop', 'tool-calls'].includes(finish)) throw new Error('provider did not finish successfully');
          self.check();
          await self.serial(async () => {
            const row = self.journal.get('events', key);
            row.attempts.findLast(a => a.turn === turn).state = 'presented';
            await self.journal.put('events', key, row);
          });
          await self.checkpoint('presented', self);
        } catch (error) {
          await self.serial(async () => {
            const row = self.journal.get('events', key);
            row.state = 'uncertain'; row.attempts.at(-1).state = 'uncertain';
            await self.journal.put('events', key, row);
          });
          throw error;
        }
      });
      // Emit listeners cannot be awaited by the host. Capture evidence then drain our own work.
      ctx.on('session/event', (session, event) => {
        if (session !== self.agent.session || event.type !== 'turn/end') return;
        const key = self.active.get(event.data.turn);
        if (!key) return;
        self.observerTail = self.observerTail.then(() => self.settle(key, event.data.turn))
          .catch(error => { self.observerErrors.push(error); });
      });
      ctx.effect(() => () => { self.closed = true; });
    } });
  }
  ownedKey(id) {
    for (const key of this.owned) if (this.journal.get('events', key)?.attempts.some(a => a.id === id)) return key;
  }
  async accept(event, { resume = false } = {}) {
    this.check();
    const key = eventKey(event);
    assert.equal(event.account, this.binding.account); assert.equal(event.consumer, this.binding.consumer);
    this.owned.add(key);
    return this.serial(async () => {
      this.check();
      let row = this.journal.get('events', key);
      if (row) { assert.equal(row.digest, digest(event), 'same event ID different content'); assert.ok(same(row.binding, this.binding), 'stale persisted binding'); }
      else {
        assert.ok(![...this.journal.domain.table('events').entries()].some(([, item]) =>
          same(item.binding, this.binding) && item.state === 'uncertain'), 'consumer has unresolved uncertainty');
        row = { binding: this.binding, event_id: event.event_id, peer: event.peer, position: event.position,
          digest: digest(event), state: 'received', attempts: [] };
        await this.journal.put('events', key, row);
        await this.checkpoint('journal-received', this);
      }
      if (['completed', 'uncertain'].includes(row.state)) return row.state;
      const previous = row.attempts.at(-1);
      if (previous && !resume) return row.state;
      if (previous && ['dispatching', 'uncertain'].includes(previous.state)) {
        row.state = 'uncertain'; await this.journal.put('events', key, row); return row.state;
      }
      if (previous?.state === 'presented') {
        // Reconcile only: never rerun a provider whose successful response may have side effects.
        return 'needs-settlement';
      }
      const enqueue = async () => {
        if (previous && previous.session !== this.agent.session.id) throw new Error('old session must be fenced before remap');
        for (const attempt of row.attempts) {
          this.agent.inbox.remove(attempt.id); // public, removes only owned pending input
          attempt.state = 'retired';
        }
        await this.flush();
        await this.checkpoint('pending-removed', this);
        const id = `bb-${key}-${row.attempts.length + 1}`;
        row.attempts.push({ id, session: this.agent.session.id, state: 'prepared' });
        row.state = 'active';
        await this.journal.put('events', key, row);
        await this.checkpoint('attempt-prepared', this);
        this.check();
        this.agent.followup({ id, role: 'user', source: { kind: 'user' }, content: event.content });
        await this.flush();
        await this.checkpoint('accepted', this);
      };
      if (resume || this.agent.status === 'idle') await this.agent.runMaintenance(enqueue);
      else await enqueue();
      return row.state;
    });
  }
  async settle(key, turn) {
    return this.serial(async () => {
      this.check();
      const row = this.journal.get('events', key);
      if (row.state === 'completed') return;
      const attempt = row.attempts.findLast(a => a.turn === turn);
      const facts = this.agent.session.snapshotEvents();
      const end = facts.find(e => e.type === 'turn/end' && e.data.turn === turn);
      const projected = facts.some(e => e.type === 'user/message' && e.data.id === attempt?.id);
      if (attempt?.state !== 'presented' || !projected || end?.data.reason.kind !== 'completed') {
        row.state = 'uncertain'; await this.journal.put('events', key, row); return;
      }
      await this.flush();
      await this.checkpoint('turn-flushed', this);
      // Client is authoritative for display receipts and contiguous consumption.
      await this.client.confirm({ binding: row.binding, key, position: row.position, attempt: attempt.id, digest: attempt.request_digest });
      await this.checkpoint('client-confirmed', this);
      this.check();
      await this.client.ack({ binding: row.binding, key, peer: row.peer, position: row.position });
      await this.checkpoint('client-acked', this);
      this.check();
      row.state = 'completed'; await this.journal.put('events', key, row);
    });
  }
  reconcile(event) {
    const key = eventKey(event);
    if (!this.recoveries.has(key)) this.recoveries.set(key, this.reconcileOnce(event));
    return this.recoveries.get(key);
  }
  async reconcileOnce(event) {
    const result = await this.accept(event, { resume: true });
    const key = eventKey(event), row = this.journal.get('events', key);
    if (result === 'needs-settlement') await this.settle(key, row.attempts.at(-1).turn);
    return this.journal.get('events', key);
  }
  async operation(logicalKey, args) {
    this.check();
    const key = digest([this.binding.account, this.binding.consumer, logicalKey]);
    return this.serial(async () => {
      this.check();
      let plan = this.journal.get('operations', key);
      if (plan) { assert.equal(plan.digest, digest(args), 'same logical operation different payload'); assert.ok(same(plan.binding, this.binding)); }
      else {
        plan = { key: logicalKey, binding: this.binding, operation_id: `bb-${key}`, args, digest: digest(args), state: 'planned' };
        await this.journal.put('operations', key, plan);
      }
      const result = await this.client.query(plan.operation_id);
      this.check();
      if (result?.status === 'succeeded') {
        assert.equal(result.operation_id, plan.operation_id);
        plan.state = 'succeeded'; plan.result = result;
        await this.journal.put('operations', key, plan); return result;
      }
      if (result || plan.state !== 'planned') {
        plan.state = 'uncertain'; await this.journal.put('operations', key, plan);
        return { operation_id: plan.operation_id, status: 'uncertain' };
      }
      plan.state = 'dispatching'; await this.journal.put('operations', key, plan);
      await this.checkpoint('operation-intent', this);
      const sent = await this.client.send(plan.operation_id, args);
      await this.checkpoint('sent-before-receipt', this);
      this.check();
      assert.equal(sent.operation_id, plan.operation_id);
      plan.state = 'succeeded'; plan.result = sent;
      await this.journal.put('operations', key, plan); return sent;
    });
  }
  async drain() {
    await this.agent.whenIdle(); await this.observerTail; await this.tail;
    if (this.observerErrors.length) throw new AggregateError(this.observerErrors.splice(0), 'consumer settlement failed');
  }
  async close() { try { await this.drain(); } finally { await this.fiber.dispose(); } }
}
