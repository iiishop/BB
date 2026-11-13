import { afterEach, describe, expect, it, vi } from 'vitest';
import { AdminApiError, createAdminApi } from '../src/api/client';
import { makeTask } from './helpers/fake-api';

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('management API client', () => {
  it('uses same-origin cookies, no CORS origin override and no web storage', async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ task: null }));
    vi.stubGlobal('fetch', fetchMock);
    const api = createAdminApi(() => null);

    await api.currentTask();

    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('/admin/api/tasks/current');
    expect(init.credentials).toBe('same-origin');
    expect(init.cache).toBe('no-store');
    expect((init.headers as Record<string, string>)['X-BB-Admin']).toBeUndefined();
  });

  it('sends CSRF and the management header on authenticated mutations only', async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);
    const api = createAdminApi(() => 'csrf-value');

    await api.changePassword('old-password', 'new-password-value');

    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    const headers = init.headers as Record<string, string>;
    expect(url).toBe('/admin/api/password');
    expect(headers['X-CSRF-Token']).toBe('csrf-value');
    expect(headers['X-BB-Admin']).toBe('1');
    expect(headers['Content-Type']).toBe('application/json');
    expect(init.body).toBe(JSON.stringify({ old_password: 'old-password', new_password: 'new-password-value' }));
  });

  it('submits a write-only token to the authorization resume seam', async () => {
    const task = makeTask({ stage: 'verifying', classification: 'running' });
    const fetchMock = vi.fn(async () => jsonResponse(task, 202));
    vi.stubGlobal('fetch', fetchMock);
    const api = createAdminApi(() => 'csrf-value');

    await api.authorizeTask(task.task_id, 'management-secret');

    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe(`/admin/api/tasks/${task.task_id}/authorization`);
    expect(init.body).toBe(JSON.stringify({ management_token: 'management-secret' }));
  });

  it('maps structured errors and the stage B 501', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        jsonResponse(
          { error: { code: 'stage_b_not_implemented', message: '阶段 B 未实现', fields: [] } },
          501,
        ),
      ),
    );
    const api = createAdminApi(() => null);

    await expect(api.getPublicConfig()).rejects.toMatchObject({
      status: 501,
      code: 'stage_b_not_implemented',
    });

    const error = await api.getPublicConfig().catch((cause: unknown) => cause);
    expect(error).toBeInstanceOf(AdminApiError);
    expect((error as AdminApiError).isStageBUnavailable).toBe(true);
  });

  it('distinguishes 401 from 403 and never echoes an unknown body', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('not json', { status: 401 })));
    const api = createAdminApi(() => null);

    const error = (await api.session().catch((cause: unknown) => cause)) as AdminApiError;
    expect(error.status).toBe(401);
    expect(error.isUnauthenticated).toBe(true);
    expect(error.message).toBe('请求失败（HTTP 401）');
  });
});
