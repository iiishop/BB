import assert from 'node:assert/strict';
import { test } from 'node:test';
import { recordScenario } from './browser_evidence.mjs';

for (const phase of ['exercise', 'cleanup', 'verify']) {
  test(`${phase} failure cannot persist a scenario PASS`, async () => {
    const results = [];
    const calls = [];
    const injected = new Error('synthetic final assertion failure');
    const steps = Object.fromEntries(['exercise', 'cleanup', 'verify'].map(step => [
      step, async () => {
        calls.push(step);
        if (step === phase) throw injected;
        return { backend: 'synthetic', external: 'none' };
      },
    ]));
    await assert.rejects(recordScenario(results, 'fixture', steps), error => error === injected);
    // This is the exact JSON representation persisted by the browser probe.
    const persisted = JSON.parse(JSON.stringify(results));
    assert.equal(persisted.some(row => row.name === 'fixture' && row.status === 'PASS'), false);
    assert.ok(calls.includes('cleanup'), 'failure must still attempt cleanup');
  });
}

test('success is published only after awaited cleanup and external effect assertions', async () => {
  const results = [];
  const calls = [];
  await recordScenario(results, 'fixture', {
    exercise: async () => { calls.push('exercise'); return { task_id: 'synthetic-task' }; },
    cleanup: async () => {
      calls.push('cleanup');
      await Promise.resolve();
      assert.equal(results.length, 0, 'cleanup must not observe a premature PASS');
    },
    verify: async () => {
      calls.push('verify');
      await Promise.resolve();
      assert.equal(results.length, 0, 'final effect assertion must precede PASS');
      assert.deepEqual({ tunnel: 1, dns: 1 }, { tunnel: 1, dns: 1 });
    },
  });
  assert.deepEqual(calls, ['exercise', 'cleanup', 'verify']);
  assert.deepEqual(results, [{ task_id: 'synthetic-task', name: 'fixture', status: 'PASS' }]);
});

test('failing later scenario preserves only earlier fully verified success', async () => {
  const results = [];
  const noop = async () => {};
  await recordScenario(results, 'native', { exercise: noop, cleanup: noop, verify: noop });
  await assert.rejects(recordScenario(results, 'fixture', {
    exercise: noop, cleanup: noop,
    verify: async () => assert.equal(2, 1, 'duplicate external effect injected'),
  }));
  assert.deepEqual(results.filter(row => row.status === 'PASS').map(row => row.name), ['native']);
});

test('cleanup failure still closes remaining handles and persists only sanitized failure', async () => {
  const { closeScenario } = await import('./browser_evidence.mjs');
  const results = [];
  const closed = [];
  await assert.rejects(recordScenario(results, 'fixture', {
    exercise: async () => ({ secret: 'PRIVATE_TEST_VALUE', status: 'PASS' }),
    cleanup: () => closeScenario([
      async () => { closed.push('context'); throw new Error('PRIVATE_TEST_VALUE'); },
      async () => { closed.push('child'); },
      async () => { closed.push('log'); },
    ]),
    verify: async () => assert.fail('cannot verify before successful cleanup'),
  }));
  assert.deepEqual(closed, ['context', 'child', 'log']);
  assert.deepEqual(JSON.parse(JSON.stringify(results)), [
    { name: 'fixture', status: 'FAIL', failed_phases: ['cleanup'] },
  ]);
  assert.equal(JSON.stringify(results).includes('PRIVATE_TEST_VALUE'), false);
});

test('exercise and cleanup failures are both retained without a PASS', async () => {
  const results = [];
  const exerciseError = new Error('exercise failed');
  const cleanupError = new Error('cleanup failed');
  await assert.rejects(recordScenario(results, 'fixture', {
    exercise: async () => { throw exerciseError; },
    cleanup: async () => { throw cleanupError; },
    verify: async () => assert.fail('unexpected verification'),
  }), error => {
    assert.ok(error instanceof AggregateError);
    assert.deepEqual(error.errors, [exerciseError, cleanupError]);
    return true;
  });
  assert.deepEqual(results, [
    { name: 'fixture', status: 'FAIL', failed_phases: ['exercise', 'cleanup'] },
  ]);
});
