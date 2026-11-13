import { createAdminState } from '../../src/stores/admin-state';
import { FakeApi } from './fake-api';

export function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

export function setup(now = () => 1_800_000_000_000) {
  const api = new FakeApi();
  let uuidCount = 0;
  const state = createAdminState(() => api, {
    now,
    uuid: () => {
      uuidCount += 1;
      return `00000000-0000-4000-8000-${String(uuidCount).padStart(12, '0')}`;
    },
  });
  return { api, state };
}

export async function readyState() {
  const ctx = setup();
  await ctx.state.restoreSession();
  await ctx.state.loadConfig();
  return ctx;
}

