import { describe, expect, it } from 'vitest';
import { AdminApiError } from '../src/api/client';
import { createAdminState } from '../src/stores/admin-state';
import { FakeApi, SESSION, makePlan, makeTask } from './helpers/fake-api';

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function setup(now = () => 1_800_000_000_000) {
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

async function readyState() {
  const ctx = setup();
  await ctx.state.restoreSession();
  await ctx.state.loadConfig();
  return ctx;
}

describe('admin state — configuration and confirmation', () => {
  it('maps the stage B 501 to an unavailable preview without claiming readiness', async () => {
    const { api, state } = setup();
    api.configResult = async () => {
      throw new AdminApiError(501, 'stage_b_not_implemented', '阶段 B 未实现');
    };
    await state.restoreSession();
    await state.loadConfig();

    expect(state.stageBUnavailable.value).toBe(true);
    expect(state.config.value).toBeNull();
    expect(state.configState.value).toBe('unavailable');
  });

  it('submits the exact plan identity and one execution on double confirm', async () => {
    const { api, state } = await readyState();
    api.probeResult = async () => makeTask({ allowed_actions: ['create_and_connect'] });
    await state.startProbe();
    await state.requestPlan('create_and_connect');
    const opened = state.plan.value;
    expect(opened).not.toBeNull();

    const first = state.confirmPlan();
    const second = state.confirmPlan();
    await Promise.all([first, second]);

    expect(api.calls.executePlan).toHaveLength(1);
    const [plan, key, token] = api.calls.executePlan[0] as [typeof opened, string, string | undefined];
    expect(plan?.plan_id).toBe(opened?.plan_id);
    expect(plan?.digest).toBe(opened?.digest);
    expect(plan?.config_version).toBe(3);
    expect(key).toMatch(UUID_RE);
    expect(key).not.toBe(`exec:${opened?.plan_id}`);
    expect(token).toBeUndefined();
    expect(state.plan.value).toBeNull();
  });

  it('reuses the same valid UUID for a retry of the same plan after a failed execution', async () => {
    const { api, state } = await readyState();
    api.probeResult = async () => makeTask({ allowed_actions: ['create_and_connect'] });
    await state.startProbe();
    await state.requestPlan('create_and_connect');
    let fail = true;
    api.executeResult = async () => {
      if (fail) {
        fail = false;
        throw new AdminApiError(503, 'storage_busy', '管理存储暂不可用');
      }
      return makeTask({
        seq: 6,
        kind: 'execute',
        stage: 'queued',
        classification: 'pending',
        allowed_actions: [],
      });
    };

    await state.confirmPlan();
    expect(api.calls.executePlan).toHaveLength(1);
    expect(state.plan.value).not.toBeNull();
    await state.confirmPlan();
    expect(api.calls.executePlan).toHaveLength(2);

    const firstKey = api.calls.executePlan[0][1];
    const secondKey = api.calls.executePlan[1][1];
    expect(firstKey).toMatch(UUID_RE);
    expect(secondKey).toBe(firstKey);
    expect(state.plan.value).toBeNull();
  });

  it('cancel sends no execution request and has no local side effect', async () => {
    const { api, state } = await readyState();
    api.probeResult = async () => makeTask({ allowed_actions: ['create_and_connect'] });
    await state.startProbe();
    await state.requestPlan('create_and_connect');
    expect(state.plan.value).not.toBeNull();

    state.cancelPlan();

    expect(state.plan.value).toBeNull();
    expect(api.calls.executePlan).toHaveLength(0);
  });

  it('saving a changed domain bumps the version and invalidates the open plan', async () => {
    const { api, state } = await readyState();
    api.probeResult = async () => makeTask({ allowed_actions: ['create_and_connect'] });
    await state.startProbe();
    await state.requestPlan('create_and_connect');
    expect(state.plan.value).not.toBeNull();

    const saved = await state.saveDomain('next.example.com');

    expect(saved).toBe(true);
    expect(api.calls.savePublicConfig).toEqual([[3, 'next.example.com']]);
    expect(state.config.value?.version).toBe(4);
    expect(state.plan.value).toBeNull();
    expect(state.notice.value).toContain('失效');
  });

  it('refuses to execute an expired plan', async () => {
    const { api, state } = await readyState();
    api.probeResult = async () => makeTask({ allowed_actions: ['create_and_connect'] });
    api.planResult = async () =>
      makePlan({ expires_at: Math.floor(1_800_000_000_000 / 1000) - 1 });
    await state.startProbe();
    await state.requestPlan('create_and_connect');

    const ok = await state.confirmPlan();

    expect(ok).toBe(false);
    expect(api.calls.executePlan).toHaveLength(0);
    expect(state.plan.value).toBeNull();
  });

  it('discards a plan when the server rejects execution with 409', async () => {
    const { api, state } = await readyState();
    api.probeResult = async () => makeTask({ allowed_actions: ['create_and_connect'] });
    api.executeResult = async () => {
      throw new AdminApiError(409, 'plan_superseded', '计划已失效');
    };
    await state.startProbe();
    await state.requestPlan('create_and_connect');
    const before = api.calls.currentTask;

    const ok = await state.confirmPlan();

    expect(ok).toBe(false);
    expect(state.plan.value).toBeNull();
    expect(state.error.value).toContain('重新探测');
    expect(api.calls.currentTask).toBe(before + 1);
  });
});

describe('admin state — idempotency and recovery', () => {
  it('reuses the probe idempotency key after a failed admission, then rotates it', async () => {
    const { api, state } = await readyState();
    let fail = true;
    api.probeResult = async () => {
      if (fail) {
        fail = false;
        throw new AdminApiError(503, 'storage_busy', '管理存储暂不可用');
      }
      return makeTask({ allowed_actions: [] });
    };

    await state.startProbe();
    await state.startProbe();
    api.probeResult = async () => makeTask({ allowed_actions: [] });
    await state.startProbe();

    const keys = api.calls.startProbe.map((call) => call[1]);
    expect(keys[0]).toBe(keys[1]);
    expect(keys[2]).not.toBe(keys[1]);
  });

  it('applies only newer task sequences and resumes from the stored sequence', async () => {
    const { api, state } = setup();
    api.currentResult = async () => ({
      task: makeTask({ seq: 5, stage: 'creating_tunnel', classification: 'running', allowed_actions: [] }),
    });
    await state.restoreSession();
    await state.loadCurrentTask();

    expect(api.calls.subscribeTask).toEqual([['11111111-1111-4111-8111-111111111111', 5]]);
    const handlers = api.lastStream?.handlers;
    handlers?.onTask(makeTask({ seq: 7, stage: 'creating_tunnel', classification: 'running', allowed_actions: [] }));
    handlers?.onTask(makeTask({ seq: 6, stage: 'creating_route', classification: 'running', allowed_actions: [] }));
    handlers?.onTask(makeTask({ seq: 7, stage: 'verifying', classification: 'running', allowed_actions: [] }));

    expect(state.task.value?.seq).toBe(7);
    expect(state.task.value?.stage).toBe('verifying');
  });

  it('reconnect after refresh subscribes from the restored server sequence, not a new task', async () => {
    const { api, state } = setup();
    api.currentResult = async () => ({
      task: makeTask({ seq: 9, stage: 'verifying', classification: 'running', allowed_actions: [] }),
    });
    await state.restoreSession();
    await state.loadCurrentTask();
    await state.loadCurrentTask();

    expect(api.calls.subscribeTask).toEqual([
      ['11111111-1111-4111-8111-111111111111', 9],
      ['11111111-1111-4111-8111-111111111111', 9],
    ]);
    expect(api.calls.startProbe).toHaveLength(0);
    expect(api.calls.executePlan).toHaveLength(0);
  });

  it('stops subscribing once a terminal snapshot arrives', async () => {
    const { api, state } = setup();
    api.currentResult = async () => ({
      task: makeTask({ seq: 4, stage: 'finished', classification: 'passed', allowed_actions: [] }),
    });
    await state.restoreSession();
    await state.loadCurrentTask();

    expect(api.calls.subscribeTask).toHaveLength(0);
    expect(state.task.value?.stage).toBe('finished');

    const { api: api2, state: state2 } = setup();
    api2.currentResult = async () => ({
      task: makeTask({ seq: 4, stage: 'verifying', classification: 'running', allowed_actions: [] }),
    });
    await state2.restoreSession();
    await state2.loadCurrentTask();
    api2.lastStream?.handlers.onTask(
      makeTask({ seq: 5, stage: 'finished', classification: 'passed', allowed_actions: [] }),
    );
    expect(api2.streamClose).toHaveBeenCalled();
  });

  it('resumes an awaiting_authorization task with the supplied token and never stores it', async () => {
    const { api, state } = setup();
    api.currentResult = async () => ({
      task: makeTask({ stage: 'awaiting_authorization', classification: 'unknown' }),
    });
    await state.restoreSession();
    await state.loadCurrentTask();
    state.openAuthorizationPrompt();
    expect(state.authorizationPrompt.value).toBe(true);

    const ok = await state.authorizeTask('secret-token-value');

    expect(ok).toBe(true);
    expect(api.calls.authorizeTask).toEqual([
      ['11111111-1111-4111-8111-111111111111', 'secret-token-value'],
    ]);
    expect(state.authorizationPrompt.value).toBe(false);
    expect(state.task.value?.stage).toBe('verifying');
    expect(JSON.stringify(localStorage)).not.toContain('secret-token-value');
    expect(JSON.stringify(sessionStorage)).not.toContain('secret-token-value');
  });
});

describe('admin state — session boundary', () => {
  it('keeps the login form on invalid credentials instead of treating it as an expired session', async () => {
    const { api, state } = setup();
    api.loginResult = async () => {
      throw new AdminApiError(401, 'invalid_credentials', '管理员账号或密码错误');
    };

    const ok = await state.login('admin', 'wrong-password');

    expect(ok).toBe(false);
    expect(state.error.value).toBe('管理员账号或密码错误');
    expect(state.notice.value).toBeNull();
    expect(state.session.value).toBeNull();
  });

  it('clears state and notifies the router on a 401', async () => {
    const { api, state } = setup();
    let redirected = false;
    state.setUnauthorizedHandler(() => {
      redirected = true;
    });
    await state.restoreSession();
    api.configResult = async () => {
      throw new AdminApiError(401, 'unauthenticated', '请重新登录');
    };

    await state.loadConfig();

    expect(redirected).toBe(true);
    expect(state.session.value).toBeNull();
    expect(state.authenticated.value).toBe(false);
    expect(state.notice.value).toContain('会话已失效');
  });

  it('returns to login after a password change and clears the CSRF token', async () => {
    const { api, state } = setup();
    api.loginResult = async () => ({ ...SESSION, must_change_password: true });
    await state.login('admin', 'admin');
    expect(state.mustChangePassword.value).toBe(true);

    const ok = await state.changePassword('admin', 'correct horse battery staple');

    expect(ok).toBe(true);
    expect(api.calls.changePassword).toEqual([['admin', 'correct horse battery staple']]);
    expect(state.session.value).toBeNull();
    expect(state.notice.value).toContain('重新登录');
  });

  it('keeps the last known task snapshot when a stream drops', async () => {
    const { api, state } = setup();
    api.currentResult = async () => ({
      task: makeTask({ seq: 2, stage: 'installing', classification: 'running', allowed_actions: [] }),
    });
    await state.restoreSession();
    await state.loadCurrentTask();
    api.lastStream?.handlers.onStateChange?.('error');

    expect(state.streamState.value).toBe('error');
    expect(state.task.value?.seq).toBe(2);
    expect(api.calls.startProbe).toHaveLength(0);
  });
});
