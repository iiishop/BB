import type {
  ActionPlan,
  AdminSession,
  AdminTask,
  ApiErrorBody,
  CurrentTask,
  ErrorField,
  PublicConfig,
} from './types';

export class AdminApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly fields: ApiErrorBody['error']['fields'];

  constructor(
    status: number,
    code: string,
    message: string,
    fields: ErrorField[] = [],
  ) {
    super(message);
    this.name = 'AdminApiError';
    this.status = status;
    this.code = code;
    this.fields = fields;
  }

  get isUnauthenticated(): boolean {
    return this.status === 401;
  }

  get isStageBUnavailable(): boolean {
    return this.status === 501 && this.code === 'stage_b_not_implemented';
  }
}

interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT';
  body?: unknown;
  signal?: AbortSignal;
  csrf?: string | null;
}

export interface PlanExecutionBody {
  plan_id: string;
  digest: string;
  expected_version: number;
  idempotency_key: string;
  confirmed: true;
  management_token?: string;
}

/**
 * Exact /executions request body. Exported so the contract regression can feed
 * the real generated body to the canonical DTO and catch invalid idempotency
 * keys before they reach the server.
 */
export function buildPlanExecutionBody(
  plan: ActionPlan,
  idempotencyKey: string,
  managementToken?: string,
): PlanExecutionBody {
  return {
    plan_id: plan.plan_id,
    digest: plan.digest,
    expected_version: plan.config_version,
    idempotency_key: idempotencyKey,
    confirmed: true,
    ...(managementToken ? { management_token: managementToken } : {}),
  };
}

export type TaskStreamHandlers = {
  onTask: (task: AdminTask) => void;
  onStateChange?: (state: 'connecting' | 'open' | 'error') => void;
};

export interface AdminApi {
  login(username: string, password: string): Promise<AdminSession>;
  session(): Promise<AdminSession>;
  changePassword(oldPassword: string, newPassword: string): Promise<void>;
  logout(): Promise<void>;
  getPublicConfig(): Promise<PublicConfig>;
  savePublicConfig(expectedVersion: number, domain: string): Promise<PublicConfig>;
  startProbe(
    expectedVersion: number,
    idempotencyKey: string,
    managementToken?: string,
  ): Promise<AdminTask>;
  createPlan(expectedVersion: number, probeTaskId: string, action: string): Promise<ActionPlan>;
  executePlan(plan: ActionPlan, idempotencyKey: string, managementToken?: string): Promise<AdminTask>;
  currentTask(): Promise<CurrentTask>;
  authorizeTask(taskId: string, managementToken: string): Promise<AdminTask>;
  subscribeTask(taskId: string, afterSeq: number, handlers: TaskStreamHandlers): () => void;
}

const BASE = '/admin/api';

async function parseError(response: Response): Promise<AdminApiError> {
  let code = `http_${response.status}`;
  let message = `请求失败（HTTP ${response.status}）`;
  let fields: ApiErrorBody['error']['fields'] = [];
  try {
    const body = (await response.json()) as Partial<ApiErrorBody>;
    if (body?.error) {
      code = body.error.code ?? code;
      message = body.error.message ?? message;
      fields = Array.isArray(body.error.fields) ? body.error.fields : [];
    }
  } catch {
    // Non-JSON error body: keep the status-based fallback. Never echo raw text.
  }
  return new AdminApiError(response.status, code, message, fields);
}

/**
 * Client for the local management origin. The bearer is an HttpOnly cookie and
 * the CSRF token stays in memory; nothing is written to web storage.
 */
export function createAdminApi(getCsrf: () => string | null): AdminApi {
  async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
    const method = options.method ?? 'GET';
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (method !== 'GET') {
      headers['Content-Type'] = 'application/json';
      headers['X-BB-Admin'] = '1';
      if (options.csrf) headers['X-CSRF-Token'] = options.csrf;
    }
    const response = await fetch(BASE + path, {
      method,
      headers,
      credentials: 'same-origin',
      cache: 'no-store',
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: options.signal,
    });
    if (!response.ok) throw await parseError(response);
    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  return {
    login: (username, password) =>
      request<AdminSession>('/login', { method: 'POST', body: { username, password } }),
    session: () => request<AdminSession>('/session'),
    changePassword: async (oldPassword, newPassword) => {
      await request<void>('/password', {
        method: 'POST',
        body: { old_password: oldPassword, new_password: newPassword },
        csrf: getCsrf(),
      });
    },
    logout: async () => {
      await request<void>('/logout', { method: 'POST', body: {}, csrf: getCsrf() });
    },
    getPublicConfig: () => request<PublicConfig>('/public-config'),
    savePublicConfig: (expectedVersion, domain) =>
      request<PublicConfig>('/public-config', {
        method: 'PUT',
        body: { expected_version: expectedVersion, domain },
        csrf: getCsrf(),
      }),
    startProbe: (expectedVersion, idempotencyKey, managementToken) =>
      request<AdminTask>('/probes', {
        method: 'POST',
        body: {
          expected_version: expectedVersion,
          idempotency_key: idempotencyKey,
          ...(managementToken ? { management_token: managementToken } : {}),
        },
        csrf: getCsrf(),
      }),
    createPlan: (expectedVersion, probeTaskId, action) =>
      request<ActionPlan>('/plans', {
        method: 'POST',
        body: { expected_version: expectedVersion, probe_task_id: probeTaskId, action },
        csrf: getCsrf(),
      }),
    executePlan: (plan, idempotencyKey, managementToken) =>
      request<AdminTask>('/executions', {
        method: 'POST',
        body: buildPlanExecutionBody(plan, idempotencyKey, managementToken),
        csrf: getCsrf(),
      }),
    currentTask: () => request<CurrentTask>('/tasks/current'),
    authorizeTask: (taskId, managementToken) =>
      request<AdminTask>(`/tasks/${taskId}/authorization`, {
        method: 'POST',
        body: { management_token: managementToken },
        csrf: getCsrf(),
      }),
    subscribeTask: (taskId, afterSeq, handlers) => {
      // Same-origin cookie-authenticated SSE. The cursor is explicit on a new
      // stream; native EventSource reconnects carry Last-Event-ID itself.
      const source = new EventSource(
        `${BASE}/tasks/${taskId}/events?after_seq=${Math.max(0, afterSeq)}`,
        { withCredentials: true },
      );
      const onOpen = () => handlers.onStateChange?.('open');
      const onError = () => handlers.onStateChange?.('error');
      const onMessage = (event: MessageEvent<string>) => {
        try {
          handlers.onTask(JSON.parse(event.data) as AdminTask);
        } catch {
          // A malformed event is ignored; the last valid snapshot remains.
        }
      };
      source.addEventListener('open', onOpen);
      source.addEventListener('error', onError);
      source.addEventListener('task', onMessage as EventListener);
      return () => {
        source.removeEventListener('open', onOpen);
        source.removeEventListener('error', onError);
        source.removeEventListener('task', onMessage as EventListener);
        source.close();
      };
    },
  };
}
