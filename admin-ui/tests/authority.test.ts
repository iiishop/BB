import { describe, it, expect } from 'vitest';
import type { AdminTask, PublicConfig } from '../src/api/types';
import { deferred, readyState } from './helpers/state';
import { CONFIG, makeTask } from './helpers/fake-api';

const NEW = '22222222-2222-4222-8222-222222222222';
// Derived from independent-hema audit, reusing the ordinary tests' FakeApi.
// Real assertions migrated from review-probes after the product fix; the test
// identities are kept stable so before/after evidence can be paired.
describe('review-only P2 authority probes', () => {
  it.each(['GET-before-PUT', 'PUT-before-GET'] as const)('%s: late response cannot roll configuration back', async (order) => {
    const { api, state } = await readyState();
    const late = deferred<PublicConfig>();
    let pending: Promise<unknown>;
    let expected: PublicConfig;
    if (order === 'GET-before-PUT') {
      api.configResult = () => late.promise;
      pending = state.loadConfig();
      state.setDomainDraft('new.example.com');
      expect(await state.saveDomain()).toBe(true);
      expected = { ...CONFIG, version: 4, domain: 'new.example.com' };
      expect(state.config.value).toEqual(expected);
      late.resolve(CONFIG);
    } else {
      api.saveResult = () => late.promise;
      state.setDomainDraft('new.example.com');
      pending = state.saveDomain();
      expected = { ...CONFIG, version: 5, domain: 'other.example.com' };
      api.configResult = async () => expected;
      await state.loadConfig();
      expect(state.config.value).toEqual(expected);
      late.resolve({ ...CONFIG, version: 4, domain: 'new.example.com' });
    }
    await pending;
    expect(state.config.value, 'configuration must retain the newest version').toEqual(expected);
  });

  it.each([2, 4])('late authorize seq=%i must retain newer task and its SSE', async (seq) => {
    const { api, state } = await readyState();
    api.currentResult = async () => ({ task: makeTask() });
    try {
      await state.loadCurrentTask();
      const late = deferred<AdminTask>();
      api.authorizeResult = () => late.promise;
      const pending = state.authorizeTask('test-token');
      api.lastStream!.handlers.onTask(makeTask({ seq: 3, stage: 'finished', classification: 'passed' }));
      api.currentResult = async () => ({ task: makeTask({ task_id: NEW, stage: 'detecting', classification: 'running' }) });
      await state.loadCurrentTask();
      const closesBefore = api.streamClose.mock.calls.length;
      expect(state.task.value?.task_id).toBe(NEW);
      late.resolve(makeTask({ seq }));
      await pending;
      expect.soft(state.task.value?.task_id, 'authorization must retain NEW task').toBe(NEW);
      expect.soft(api.streamClose.mock.calls.length, 'authorization must not close NEW SSE').toBe(closesBefore);
      expect(api.lastStream?.taskId).toBe(NEW);
    } finally {
      state.closeTaskStream();
    }
  });
});
