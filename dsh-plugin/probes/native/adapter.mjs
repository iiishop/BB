// Admission-only experimental adapter. Deliberately NOT a production scheduler.
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

export class AdmissionProbe {
  constructor(ctx, agent, account) {
    this.ctx = ctx;
    this.agent = agent;
    this.account = account;
  }

  message(event) {
    assert.equal(event.account, this.account, 'account binding mismatch');
    assert.equal(event.session_id, this.agent.session.id, 'session binding mismatch');
    assert.equal(typeof event.event_id, 'string');
    assert.ok(event.event_id.length > 0);
    assert.ok(['message.available', 'download.succeeded', 'download.failed'].includes(event.type));
    const identity = JSON.stringify([event.account, event.session_id, event.event_id]);
    const id = 'bb-probe-' + createHash('sha256').update(identity).digest('hex');
    return {
      id, role: 'user', source: { kind: 'user' },
      content: [{ type: 'text', text: JSON.stringify({
        account: event.account, session_id: event.session_id, event_id: event.event_id,
        type: event.type, payload: event.payload,
      }) }],
    };
  }

  inspect(event) {
    const message = this.message(event);
    const events = this.agent.session.snapshotEvents();
    const insertions = events.filter(item => item.type === 'agent/inbox/spliced'
      && item.data.inserted.some(candidate => candidate.id === message.id));
    for (const insertion of insertions) {
      assert.deepEqual(insertion.data.inserted.find(item => item.id === message.id), message,
        'same event key with different payload');
    }
    const pending = [...this.agent.inbox.nextTurn, ...this.agent.inbox.nextStep]
      .some(item => item.id === message.id);
    const projected = events.some(item => item.type === 'user/message' && item.data.id === message.id);
    return {
      message_id: message.id, insertions: insertions.length,
      pending, history_projected: projected,
      state: insertions.length === 0 ? 'absent'
        : pending ? 'accepted_pending'
          : projected ? 'history_projected' : 'accepted_unpresented',
      // Neither queue insertion nor user/message proves provider presentation/consumption.
      model_presented: 'unknown', consumed_through: null,
    };
  }

  async accept(event, { wake = false } = {}) {
    // Single real Session writer. No await between reading facts and native insertion:
    // concurrent JS callers/adapter instances cannot pass this check together.
    const prior = this.inspect(event);
    if (prior.state === 'absent') this.agent.send(this.message(event), 'next-turn', wake);
    // No external dedup table: the insertion is BOTH the acceptance record and inbox fact.
    assert.equal(await this.ctx.sessions.flush(this.agent.session), true);
    return { ...this.inspect(event), disposition: prior.state === 'absent' ? 'new' : 'existing' };
  }
}
