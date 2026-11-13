import { vi } from 'vitest';
import type { AdminApi, TaskStreamHandlers } from '../../src/api/client';
import type {
  ActionPlan,
  AdminSession,
  AdminTask,
  CurrentTask,
  PublicConfig,
} from '../../src/api/types';

export const SESSION: AdminSession = {
  username: 'admin',
  must_change_password: false,
  csrf_token: 'csrf-test',
  expires_at: 4_102_444_800,
};

export const CONFIG: PublicConfig = {
  version: 3,
  domain: 'bb.example.com',
  active: null,
};

export function makeTask(overrides: Partial<AdminTask> = {}): AdminTask {
  return {
    task_id: '11111111-1111-4111-8111-111111111111',
    seq: 1,
    config_version: 3,
    kind: 'probe',
    stage: 'awaiting_authorization',
    classification: 'unknown',
    issue_code: 'authorization_missing',
    allowed_actions: ['authorize'],
    requires_confirmation: false,
    checks: [],
    resources: [],
    message: '需要管理权限',
    ...overrides,
  };
}

export function makePlan(overrides: Partial<ActionPlan> = {}): ActionPlan {
  return {
    plan_id: '22222222-2222-4222-8222-222222222222',
    config_version: 3,
    digest: 'a'.repeat(64),
    domain: 'bb.example.com',
    target_service: '127.0.0.1:8000',
    resources: [{ kind: 'tunnel', operation: 'create', name: 'bb-admin' }],
    public_scope: ['业务 API'],
    risks: ['将创建 Cloudflare 资源'],
    requires_confirmation: true,
    expires_at: 4_102_444_800,
    ...overrides,
  };
}

export class FakeApi implements AdminApi {
  sessionResult: () => Promise<AdminSession> = async () => SESSION;
  loginResult: () => Promise<AdminSession> = async () => SESSION;
  configResult: () => Promise<PublicConfig> = async () => CONFIG;
  saveResult: (version: number, domain: string) => Promise<PublicConfig> = async (version, domain) => ({
    version: version + 1,
    domain,
    active: null,
  });
  probeResult: () => Promise<AdminTask> = async () => makeTask();
  planResult: () => Promise<ActionPlan> = async () => makePlan();
  executeResult: () => Promise<AdminTask> = async () => makeTask({ kind: 'execute', stage: 'queued', classification: 'pending', allowed_actions: [] });
  currentResult: () => Promise<CurrentTask> = async () => ({ task: null });
  authorizeResult: () => Promise<AdminTask> = async () =>
    makeTask({ seq: 2, stage: 'verifying', classification: 'running', allowed_actions: [] });

  calls = {
    login: [] as unknown[][],
    session: 0,
    changePassword: [] as unknown[][],
    logout: 0,
    getPublicConfig: 0,
    savePublicConfig: [] as unknown[][],
    startProbe: [] as unknown[][],
    createPlan: [] as unknown[][],
    executePlan: [] as unknown[][],
    currentTask: 0,
    authorizeTask: [] as unknown[][],
    subscribeTask: [] as unknown[][],
  };

  lastStream: { taskId: string; afterSeq: number; handlers: TaskStreamHandlers } | null = null;
  streamClose = vi.fn();

  login = vi.fn(async (username: string, password: string) => {
    this.calls.login.push([username, password]);
    return this.loginResult();
  });

  session = vi.fn(async () => {
    this.calls.session += 1;
    return this.sessionResult();
  });

  changePassword = vi.fn(async (oldPassword: string, newPassword: string) => {
    this.calls.changePassword.push([oldPassword, newPassword]);
  });

  logout = vi.fn(async () => {
    this.calls.logout += 1;
  });

  getPublicConfig = vi.fn(async () => {
    this.calls.getPublicConfig += 1;
    return this.configResult();
  });

  savePublicConfig = vi.fn(async (expectedVersion: number, domain: string) => {
    this.calls.savePublicConfig.push([expectedVersion, domain]);
    return this.saveResult(expectedVersion, domain);
  });

  startProbe = vi.fn(async (version: number, key: string, token?: string) => {
    this.calls.startProbe.push([version, key, token]);
    return this.probeResult();
  });

  createPlan = vi.fn(async (version: number, probeTaskId: string, action: string) => {
    this.calls.createPlan.push([version, probeTaskId, action]);
    return this.planResult();
  });

  executePlan = vi.fn(async (plan: ActionPlan, key: string, token?: string) => {
    this.calls.executePlan.push([plan, key, token]);
    return this.executeResult();
  });

  currentTask = vi.fn(async () => {
    this.calls.currentTask += 1;
    return this.currentResult();
  });

  authorizeTask = vi.fn(async (taskId: string, token: string) => {
    this.calls.authorizeTask.push([taskId, token]);
    return this.authorizeResult();
  });

  subscribeTask = vi.fn((taskId: string, afterSeq: number, handlers: TaskStreamHandlers) => {
    this.calls.subscribeTask.push([taskId, afterSeq]);
    this.lastStream = { taskId, afterSeq, handlers };
    return () => {
      this.streamClose();
    };
  });
}
