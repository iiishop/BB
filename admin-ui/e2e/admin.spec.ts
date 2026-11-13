import { mkdirSync } from 'node:fs';
import { expect, test, type Page, type Route } from '@playwright/test';
import type { ActionPlan, AdminTask } from '../src/api/types';

const INITIAL_PASSWORD = 'admin';
const NEW_PASSWORD = 'Muse-Admin-Pass-2026';
const TASK_ID = '33333333-3333-4333-8333-333333333333';
const DOMAIN = 'bb.muse-preview.test';
const CHANGED_DOMAIN = 'bb.muse-preview-2.test';
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type MockState = {
  version: number;
  domain: string | null;
  currentTask: AdminTask | null;
  plans: number;
  executions: number;
  probes: number;
  authorizations: number;
  lastPlan: ActionPlan | null;
  lastExecution: Record<string, unknown> | null;
  executionKeys: string[];
  sse: number;
};

function probeTask(options: {
  stage: AdminTask['stage'];
  classification: AdminTask['classification'];
  allowed: AdminTask['allowed_actions'];
  version: number;
  message: string;
  checks?: AdminTask['checks'];
  resources?: AdminTask['resources'];
  kind?: AdminTask['kind'];
  seq?: number;
}): AdminTask {
  return {
    task_id: TASK_ID,
    seq: options.seq ?? (options.stage === 'finished' ? 5 : 2),
    config_version: options.version,
    kind: options.kind ?? 'probe',
    stage: options.stage,
    classification: options.classification,
    issue_code: options.classification === 'unknown' ? 'management_token_required' : null,
    allowed_actions: options.allowed,
    requires_confirmation: false,
    checks: options.checks ?? [],
    resources: options.resources ?? [],
    message: options.message,
  };
}

function planFor(state: MockState): ActionPlan {
  state.plans += 1;
  const plan: ActionPlan = {
    plan_id: `44444444-4444-4444-8444-${String(state.plans).padStart(12, '0')}`,
    config_version: state.version,
    digest: `d${String(state.plans).padStart(63, '0')}`,
    domain: state.domain ?? DOMAIN,
    target_service: '127.0.0.1:8000',
    resources: [
      { kind: 'package', operation: 'reuse', name: 'cloudflared' },
      { kind: 'tunnel', operation: 'create', name: 'bb-preview' },
      { kind: 'dns', operation: 'create', name: state.domain ?? DOMAIN },
    ],
    public_scope: ['业务 API：资料、聊天与媒体下载'],
    risks: [
      '将创建 Cloudflare Tunnel 与 DNS 记录',
      '公网只公开业务 API，管理页与管理接口不得经 Tunnel 访问',
    ],
    requires_confirmation: true,
    expires_at: Math.floor(Date.now() / 1000) + 600,
  };
  state.lastPlan = plan;
  return plan;
}

async function json(route: Route, status: number, body: unknown) {
  await route.fulfill({
    status,
    contentType: 'application/json',
    body: JSON.stringify(body),
  });
}

async function installMockStageB(page: Page, state: MockState) {
  await page.route('**/admin/api/**', async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();

    if (path === '/admin/api/public-config') {
      if (method === 'GET') {
        return json(route, 200, { version: state.version, domain: state.domain, active: null });
      }
      const body = JSON.parse(request.postData() ?? '{}') as {
        expected_version: number;
        domain: string;
      };
      if (body.expected_version !== state.version) {
        return json(route, 409, {
          error: { code: 'config_version_conflict', message: '配置版本冲突', fields: [] },
        });
      }
      state.version += 1;
      state.domain = body.domain;
      return json(route, 200, { version: state.version, domain: state.domain, active: null });
    }

    if (path === '/admin/api/probes' && method === 'POST') {
      state.probes += 1;
      state.currentTask = probeTask({
        stage: 'awaiting_authorization',
        classification: 'unknown',
        allowed: ['authorize'],
        version: state.version,
        message: '需要最小权限的 Cloudflare 管理凭据才能继续。',
        checks: [
          { check: 'installation', classification: 'passed', issue_code: null, message: 'cloudflared 已安装', allowed_actions: [] },
          { check: 'service', classification: 'passed', issue_code: null, message: '系统服务状态正常', allowed_actions: [] },
          { check: 'connection', classification: 'unknown', issue_code: 'authorization_missing', message: '缺少管理权限，无法读取 Tunnel 列表', allowed_actions: ['authorize'] },
          { check: 'route', classification: 'not_applicable', issue_code: null, message: '尚未生效域名', allowed_actions: [] },
        ],
      });
      return json(route, 202, state.currentTask);
    }

    if (path === `/admin/api/tasks/${TASK_ID}/authorization` && method === 'POST') {
      state.authorizations += 1;
      const body = JSON.parse(request.postData() ?? '{}') as { management_token?: string };
      if (body.management_token !== 'e2e-secret-token') {
        return json(route, 409, {
          error: { code: 'task_not_awaiting_authorization', message: '凭据无效', fields: [] },
        });
      }
      state.currentTask = probeTask({
        stage: 'finished',
        classification: 'passed',
        allowed: ['create_and_connect'],
        version: state.version,
        message: '检测通过：可以创建并连接 Tunnel。',
        checks: [
          { check: 'installation', classification: 'passed', issue_code: null, message: 'cloudflared 已安装', allowed_actions: [] },
          { check: 'service', classification: 'passed', issue_code: null, message: '系统服务状态正常', allowed_actions: [] },
          { check: 'connection', classification: 'passed', issue_code: null, message: '账号可管理 Tunnel', allowed_actions: [] },
          { check: 'authorization', classification: 'passed', issue_code: null, message: '管理权限有效', allowed_actions: [] },
          { check: 'route', classification: 'not_applicable', issue_code: null, message: '尚未创建 DNS 路由', allowed_actions: ['create_and_connect'] },
          { check: 'instance', classification: 'not_applicable', issue_code: null, message: '尚未连接', allowed_actions: [] },
        ],
      });
      return json(route, 202, state.currentTask);
    }

    if (path === '/admin/api/plans' && method === 'POST') {
      return json(route, 201, planFor(state));
    }

    if (path === '/admin/api/executions' && method === 'POST') {
      const body = JSON.parse(request.postData() ?? '{}') as Record<string, unknown>;
      state.executions += 1;
      state.lastExecution = body;
      state.executionKeys.push(String(body.idempotency_key ?? ''));
      // Mirror the server's canonical UUID requirement so a regression fails
      // here instead of only after integration.
      if (!UUID_RE.test(String(body.idempotency_key ?? ''))) {
        return json(route, 422, {
          error: {
            code: 'validation_error',
            message: '请求字段校验失败',
            fields: [{ field: 'idempotency_key', code: 'uuid_parsing' }],
          },
        });
      }
      const plan = state.lastPlan;
      if (
        !plan ||
        body.plan_id !== plan.plan_id ||
        body.digest !== plan.digest ||
        body.expected_version !== state.version ||
        plan.config_version !== state.version
      ) {
        return json(route, 409, {
          error: { code: 'plan_superseded', message: '计划或配置已变化', fields: [] },
        });
      }
      state.currentTask = probeTask({
        stage: 'queued',
        classification: 'pending',
        allowed: [],
        version: state.version,
        kind: 'execute',
        seq: 6,
        message: '已接受执行计划，等待服务端开始创建资源。',
      });
      return json(route, 202, state.currentTask);
    }

    if (path === '/admin/api/tasks/current' && method === 'GET') {
      return json(route, 200, { task: state.currentTask });
    }

    if (path === `/admin/api/tasks/${TASK_ID}/events` && method === 'GET') {
      state.sse += 1;
      const snapshot = state.currentTask;
      const body = snapshot
        ? `retry: 60000\n\nid: ${snapshot.seq}\nevent: task\ndata: ${JSON.stringify(snapshot)}\n\n`
        : 'retry: 60000\n\n';
      return route.fulfill({
        status: 200,
        headers: {
          'content-type': 'text/event-stream',
          'cache-control': 'no-store',
        },
        body,
      });
    }

    if (path === `/admin/api/tasks/${TASK_ID}` && method === 'GET') {
      return state.currentTask ? json(route, 200, state.currentTask) : json(route, 404, {
        error: { code: 'task_not_found', message: '任务不存在', fields: [] },
      });
    }

    return route.continue();
  });
}

test('DEA-469 admin UI: real stage A backend, then stage B contract preview @real-a @b-preview', async ({
  page,
}) => {
  mkdirSync('.evidence/screens', { recursive: true });
  const pageErrors: string[] = [];
  const cspViolations: string[] = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  page.on('console', (message) => {
    const text = message.text();
    if (/Content Security Policy|Refused to/i.test(text)) cspViolations.push(text);
  });
  const shot = (name: string) =>
    page.screenshot({ path: `.evidence/screens/${name}.png`, fullPage: true });
  const shotViewport = (name: string) =>
    page.screenshot({ path: `.evidence/screens/${name}.png`, fullPage: false });

  // --- Real stage A: initial login, forced password change, session restore.
  await page.goto('/admin/login');
  await expect(page.getByRole('heading', { name: '管理员登录' })).toBeVisible();
  await shot('01-login');

  await page.getByLabel('用户名').fill('admin');
  await page.getByLabel('密码', { exact: true }).fill(INITIAL_PASSWORD);
  await page.getByRole('button', { name: '登录' }).click();
  await expect(page.getByRole('heading', { name: '修改管理员密码' })).toBeVisible();
  await shot('02-forced-password-change');

  await page.getByLabel('当前密码').fill(INITIAL_PASSWORD);
  await page.getByLabel(/^新密码/).fill(NEW_PASSWORD);
  await page.getByLabel('再次输入新密码').fill(NEW_PASSWORD);
  await page.getByRole('button', { name: '修改密码并退出所有会话' }).click();
  await expect(page.getByRole('heading', { name: '管理员登录' })).toBeVisible();
  await expect(page.getByText('密码已修改，所有旧会话已失效')).toBeVisible();
  await shot('03-password-rotated-relogin');

  // The old password must no longer authenticate.
  await page.getByLabel('密码', { exact: true }).fill(INITIAL_PASSWORD);
  await page.getByRole('button', { name: '登录' }).click();
  await expect(page.getByText('管理员账号或密码错误')).toBeVisible();

  await page.getByLabel('密码', { exact: true }).fill(NEW_PASSWORD);
  await page.getByRole('button', { name: '登录' }).click();
  await expect(page.getByRole('heading', { name: '欢迎，admin' })).toBeVisible();
  await expect(page.locator('nav .nav__link')).toHaveCount(2);
  await expect(page.locator('nav .nav__link').nth(0)).toHaveText('Home');
  await expect(page.locator('nav .nav__link').nth(1)).toHaveText('配置');
  await shot('04-home');

  // Real GET /public-config is still the stage B 501 handler.
  const notImplemented = page.waitForResponse(
    (response) =>
      response.request().method() === 'GET' &&
      response.url().endsWith('/admin/api/public-config'),
  );
  await page.getByRole('link', { name: '配置', exact: true }).click();
  const realConfigResponse = await notImplemented;
  expect(realConfigResponse.status()).toBe(501);
  await expect(page.getByText('阶段 B 尚未接通')).toBeVisible();
  await expect(page.getByText('501 stage_b_not_implemented')).toBeVisible();
  await shot('05-config-real-backend-501');

  // Refresh restores the real session and keeps the 501 preview, without login.
  const restoredConfig = page.waitForResponse((response) =>
    response.url().endsWith('/admin/api/public-config'),
  );
  await page.reload();
  expect((await restoredConfig).status()).toBe(501);
  await expect(page.getByRole('heading', { name: '配置' })).toBeVisible();
  await expect(page.getByText('阶段 B 尚未接通')).toBeVisible();

  // --- Stage B contract preview: real stage A session/auth, mocked B routes.
  const mock: MockState = {
    version: 3,
    domain: null,
    currentTask: null,
    plans: 0,
    executions: 0,
    probes: 0,
    authorizations: 0,
    lastPlan: null,
    lastExecution: null,
    executionKeys: [],
    sse: 0,
  };
  await installMockStageB(page, mock);
  await page.reload();
  await expect(page.getByRole('heading', { name: '配置' })).toBeVisible();
  await expect(page.getByText('阶段 B 尚未接通')).toHaveCount(0);

  // Draft save vs active configuration.
  const domainInput = page.locator('input[placeholder="bb.example.com"]');
  await domainInput.fill(DOMAIN);
  await page.getByRole('button', { name: '保存域名草稿' }).click();
  await expect(page.getByText('草稿已保存')).toBeVisible();
  expect(mock.version).toBe(4);
  await expect(page.getByText('尚未生效')).toBeVisible();

  // Probe → single capsule in awaiting_authorization.
  await page.getByRole('button', { name: '开始只读探测' }).click();
  await expect(page.getByText('等待管理凭据').first()).toBeVisible();
  await expect(page.getByRole('button', { name: '补充管理凭据' })).toBeVisible();
  expect(mock.probes).toBe(1);
  await shot('06-capsule-awaiting-authorization');

  // Authorization resume seam (addendum) then server-selected action.
  await page.getByRole('button', { name: '补充管理凭据' }).click();
  const tokenDialog = page.getByRole('dialog', { name: '补充管理凭据' });
  await expect(tokenDialog).toBeVisible();
  await tokenDialog.getByLabel(/^管理 API Token/).fill('e2e-secret-token');
  await tokenDialog.getByRole('button', { name: '提交凭据并恢复任务' }).click();
  await expect(page.getByRole('button', { name: '创建并连接 Tunnel' })).toBeVisible();
  expect(mock.authorizations).toBe(1);
  await expect(page.getByText('通过').first()).toBeVisible();

  // Confirmation dialog: cancel has no side effect.
  await page.getByRole('button', { name: '创建并连接 Tunnel' }).click();
  const planDialog = page.getByRole('dialog', { name: '确认公网执行计划' });
  await expect(planDialog).toBeVisible();
  await expect(planDialog).toContainText(DOMAIN);
  await expect(planDialog).toContainText('127.0.0.1:8000');
  await expect(planDialog).toContainText('业务 API');
  await expect(planDialog).toContainText('将创建 Cloudflare Tunnel 与 DNS 记录');
  await shotViewport('07-confirm-plan');
  await planDialog.getByRole('button', { name: '取消' }).click();
  await expect(planDialog).toBeHidden();
  expect(mock.executions).toBe(0);

  // Same intent reopened: the plan remains explicit; double click yields one request.
  await page.getByRole('button', { name: '创建并连接 Tunnel' }).click();
  const secondDialog = page.getByRole('dialog', { name: '确认公网执行计划' });
  await expect(secondDialog).toBeVisible();
  await secondDialog.getByRole('checkbox').check();
  const confirmButton = secondDialog.getByRole('button', { name: '确认并执行' });
  await confirmButton.evaluate((element) => {
    element.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    element.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await expect(secondDialog).toBeHidden();
  expect(mock.executions).toBe(1);
  expect(mock.lastExecution?.plan_id).toBe(mock.lastPlan?.plan_id);
  expect(mock.lastExecution?.digest).toBe(mock.lastPlan?.digest);
  expect(mock.lastExecution?.expected_version).toBe(mock.lastPlan?.config_version);
  expect(mock.lastExecution?.idempotency_key).toMatch(UUID_RE);
  expect(mock.lastExecution?.idempotency_key).not.toContain('exec:');
  expect(mock.executionKeys).toHaveLength(1);
  await expect(page.getByText('已排队').first()).toBeVisible();
  await shot('08-task-queued-after-confirm');

  // Refresh restore: server /tasks/current is terminal; no new task is created.
  mock.currentTask = probeTask({
    stage: 'finished',
    classification: 'passed',
    allowed: ['verify'],
    version: mock.version,
    kind: 'execute',
    seq: 7,
    message: '公网实例挑战匹配，配置已生效。',
    checks: [
      { check: 'installation', classification: 'passed', issue_code: null, message: 'cloudflared 已安装', allowed_actions: [] },
      { check: 'service', classification: 'passed', issue_code: null, message: '系统服务运行中', allowed_actions: [] },
      { check: 'connection', classification: 'passed', issue_code: null, message: 'Tunnel 已连接', allowed_actions: [] },
      { check: 'route', classification: 'passed', issue_code: null, message: 'DNS 路由已创建', allowed_actions: [] },
      { check: 'instance', classification: 'passed', issue_code: null, message: '短期随机挑战匹配', allowed_actions: [] },
    ],
    resources: [
      { kind: 'tunnel', resource_id: 'tunnel-preview-1234', ownership: 'created_by_task' },
      { kind: 'dns', resource_id: `${DOMAIN} -> tunnel-preview-1234`, ownership: 'created_by_task' },
    ],
  });
  const afterReload = page.waitForResponse((response) =>
    response.url().endsWith('/admin/api/tasks/current'),
  );
  await page.reload();
  await afterReload;
  await expect(page.getByText('公网验证通过')).toBeVisible();
  await expect(page.getByText('本次创建').first()).toBeVisible();
  expect(mock.executions).toBe(1);
  await shot('09-refresh-restored-terminal-task');

  // Domain change + stale plan: server 409 must discard the confirmation.
  await page.locator('input[placeholder="bb.example.com"]').fill(CHANGED_DOMAIN);
  await page.getByRole('button', { name: '保存域名草稿' }).click();
  await expect(page.getByText('域名已保存为草稿')).toBeVisible();
  expect(mock.version).toBe(5);
  await page.getByRole('button', { name: '验证公网实例' }).click();
  const staleDialog = page.getByRole('dialog', { name: '确认公网执行计划' });
  await expect(staleDialog).toBeVisible();
  await expect(staleDialog).toContainText(CHANGED_DOMAIN);
  mock.version = 6; // Another tab saved a newer configuration.
  await staleDialog.getByRole('checkbox').check();
  await staleDialog.getByRole('button', { name: '确认并执行' }).click();
  await expect(staleDialog).toBeHidden();
  await expect(page.getByText('服务端拒绝了本次执行')).toBeVisible();
  expect(mock.executions).toBe(2);
  expect(mock.executionKeys).toHaveLength(2);
  expect(mock.executionKeys.every((key) => UUID_RE.test(key))).toBe(true);
  expect(mock.executionKeys[1]).not.toBe(mock.executionKeys[0]);
  await shot('10-stale-plan-rejected-409');

  // Responsive: 390x844 mobile viewport on the same real build.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/admin/home');
  await expect(page.getByRole('heading', { name: '欢迎，admin' })).toBeVisible();
  await shot('11-mobile-home');
  await page.goto('/admin/config');
  await expect(page.getByRole('heading', { name: '配置' })).toBeVisible();
  await shot('12-mobile-config');

  // Real logout still works against the real stage A app.
  await page.getByRole('button', { name: '退出登录' }).click();
  await expect(page.getByRole('heading', { name: '管理员登录' })).toBeVisible();

  expect(cspViolations, cspViolations.join('\n')).toEqual([]);
  expect(pageErrors, pageErrors.join('\n')).toEqual([]);
});
