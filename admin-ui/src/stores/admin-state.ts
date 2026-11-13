import { computed, ref, shallowRef } from 'vue';
import {
  AdminApiError,
  createAdminApi,
  type AdminApi,
  type TaskStreamHandlers,
} from '../api/client';
import {
  isNonTerminalTask,
  type Action,
  type ActionPlan,
  type AdminSession,
  type AdminTask,
  type PublicConfig,
} from '../api/types';

export type BusyAction =
  | 'login'
  | 'password'
  | 'logout'
  | 'save'
  | 'probe'
  | 'plan'
  | 'execute'
  | 'authorize'
  | null;

export interface AdminStateOptions {
  now?: () => number;
  uuid?: () => string;
}

export type AdminApiFactory = (getCsrf: () => string | null) => AdminApi;

function defaultUuid(): string {
  return crypto.randomUUID();
}

function messageOf(error: unknown): string {
  if (error instanceof AdminApiError) return error.message;
  return '无法连接到本机管理入口，请确认 bb-admin 正在运行。';
}

/**
 * Single client-side owner of the management session, configuration snapshot
 * and current task. The server remains the only task/config truth; this store
 * never recreates a task because a request or stream disconnected.
 */
export function createAdminState(
  apiFactory: AdminApiFactory = createAdminApi,
  options: AdminStateOptions = {},
) {
  const now = options.now ?? (() => Date.now());
  const uuid = options.uuid ?? defaultUuid;

  let csrfToken: string | null = null;
  const api = apiFactory(() => csrfToken);

  const session = ref<AdminSession | null>(null);
  const config = ref<PublicConfig | null>(null);
  const task = ref<AdminTask | null>(null);
  const plan = ref<ActionPlan | null>(null);
  const error = ref<string | null>(null);
  const notice = ref<string | null>(null);
  const stageBUnavailable = ref(false);
  const configState = ref<'idle' | 'loading' | 'ready' | 'unavailable' | 'error'>('idle');
  const taskState = ref<'idle' | 'loading' | 'ready' | 'unavailable' | 'error'>('idle');
  const streamState = ref<'idle' | 'connecting' | 'open' | 'error'>('idle');
  const busy = ref<BusyAction>(null);
  const restoring = ref(false);
  const authorizationPrompt = ref(false);
  const unauthorizedHandler = shallowRef<(() => void) | null>(null);

  let closeStream: (() => void) | null = null;
  let probeKey: string | null = null;
  const executeKeys = new Map<string, string>();

  function setCsrf(value: string | null) {
    csrfToken = value;
  }

  function closeTaskStream() {
    closeStream?.();
    closeStream = null;
    streamState.value = 'idle';
  }

  function applySession(next: AdminSession | null) {
    session.value = next;
    setCsrf(next?.csrf_token ?? null);
  }

  function clearSession(noticeText?: string) {
    applySession(null);
    closeTaskStream();
    executeKeys.clear();
    config.value = null;
    task.value = null;
    plan.value = null;
    configState.value = 'idle';
    taskState.value = 'idle';
    if (noticeText) notice.value = noticeText;
  }

  function handleUnauthorized() {
    clearSession('管理会话已失效，请重新登录。');
    unauthorizedHandler.value?.();
  }

  function handleError(cause: unknown, fallback?: string) {
    if (cause instanceof AdminApiError) {
      if (cause.isUnauthenticated) {
        handleUnauthorized();
        return;
      }
      if (cause.isStageBUnavailable) {
        stageBUnavailable.value = true;
        error.value = '阶段 B 尚未接通：服务端返回 501 stage_b_not_implemented，未产生任何外部副作用。';
        return;
      }
    }
    error.value = cause instanceof AdminApiError ? cause.message : (fallback ?? messageOf(cause));
  }

  function applyConfig(next: PublicConfig) {
    const previous = config.value;
    config.value = next;
    configState.value = 'ready';
    if (previous && previous.version !== next.version) invalidatePlan();
  }

  function applyTask(next: AdminTask) {
    const current = task.value;
    if (current && current.task_id === next.task_id && next.seq < current.seq) {
      return; // Duplicate/older sequence: keep the newest snapshot.
    }
    task.value = next;
    taskState.value = 'ready';
    if (next.stage === 'finished') {
      closeTaskStream();
      probeKey = null;
    }
  }

  function streamTask(nextTask: AdminTask) {
    closeTaskStream();
    if (nextTask.stage === 'finished') return;
    streamState.value = 'connecting';
    const handlers: TaskStreamHandlers = {
      onTask: applyTask,
      onStateChange: (state) => {
        streamState.value = state;
      },
    };
    closeStream = api.subscribeTask(nextTask.task_id, nextTask.seq, handlers);
  }

  function applyTaskAndStream(next: AdminTask) {
    applyTask(next);
    if (isNonTerminalTask(next)) streamTask(next);
  }

  function invalidatePlan(reason?: string) {
    if (!plan.value) return;
    plan.value = null;
    notice.value = reason ?? '确认计划已失效，请重新探测并确认。';
  }

  async function restoreSession(): Promise<boolean> {
    restoring.value = true;
    try {
      applySession(await api.session());
      return true;
    } catch (cause) {
      if (cause instanceof AdminApiError && cause.isUnauthenticated) {
        clearSession();
      } else {
        error.value = messageOf(cause);
      }
      return false;
    } finally {
      restoring.value = false;
    }
  }

  async function login(username: string, password: string): Promise<boolean> {
    error.value = null;
    notice.value = null;
    busy.value = 'login';
    try {
      applySession(await api.login(username, password));
      return true;
    } catch (cause) {
      // A 401 from /login means wrong credentials, not an expired session:
      // keep the form and never redirect through the session-expiry path.
      if (cause instanceof AdminApiError && (cause.isUnauthenticated || cause.status === 429)) {
        error.value = cause.message;
      } else {
        handleError(cause, '无法连接本机管理入口，请确认 bb-admin 正在运行。');
      }
      return false;
    } finally {
      busy.value = null;
    }
  }

  async function changePassword(oldPassword: string, newPassword: string): Promise<boolean> {
    error.value = null;
    busy.value = 'password';
    try {
      await api.changePassword(oldPassword, newPassword);
      clearSession('密码已修改，所有旧会话已失效，请用新密码重新登录。');
      return true;
    } catch (cause) {
      handleError(cause, '修改密码失败，请重试。');
      return false;
    } finally {
      busy.value = null;
    }
  }

  async function logout(): Promise<void> {
    busy.value = 'logout';
    try {
      await api.logout();
    } catch (cause) {
      if (!(cause instanceof AdminApiError && cause.isUnauthenticated)) {
        // Logout still clears local state; report rather than block exit.
        error.value = messageOf(cause);
      }
    } finally {
      clearSession();
      busy.value = null;
    }
  }

  async function loadConfig(): Promise<void> {
    configState.value = 'loading';
    try {
      config.value = await api.getPublicConfig();
      stageBUnavailable.value = false;
      configState.value = 'ready';
    } catch (cause) {
      if (cause instanceof AdminApiError && cause.isStageBUnavailable) {
        stageBUnavailable.value = true;
        config.value = null;
        configState.value = 'unavailable';
        return;
      }
      if (cause instanceof AdminApiError && cause.isUnauthenticated) {
        handleUnauthorized();
        configState.value = 'error';
        return;
      }
      handleError(cause, '读取公网配置失败。');
      configState.value = 'error';
    }
  }

  async function loadCurrentTask(): Promise<void> {
    taskState.value = 'loading';
    try {
      const current = await api.currentTask();
      stageBUnavailable.value = false;
      if (current.task) {
        applyTaskAndStream(current.task);
      } else {
        closeTaskStream();
        task.value = null;
        taskState.value = 'ready';
      }
    } catch (cause) {
      if (cause instanceof AdminApiError && cause.isStageBUnavailable) {
        stageBUnavailable.value = true;
        task.value = null;
        taskState.value = 'unavailable';
        return;
      }
      if (cause instanceof AdminApiError && cause.isUnauthenticated) {
        handleUnauthorized();
        taskState.value = 'error';
        return;
      }
      handleError(cause, '读取当前任务失败。');
      taskState.value = 'error';
    }
  }

  async function refreshWorkspace(): Promise<void> {
    await Promise.all([loadConfig(), loadCurrentTask()]);
  }

  async function saveDomain(domain: string): Promise<boolean> {
    if (!config.value) return false;
    error.value = null;
    notice.value = null;
    busy.value = 'save';
    try {
      const hadPlan = plan.value !== null;
      applyConfig(await api.savePublicConfig(config.value.version, domain.trim()));
      notice.value = hadPlan
        ? '域名已保存为草稿，原确认计划已失效；请重新探测并确认后才会生效。'
        : '域名已保存为草稿；需要重新探测、计划并确认后才会生效。';
      return true;
    } catch (cause) {
      if (cause instanceof AdminApiError && cause.status === 409) {
        error.value = '配置版本已变化，请刷新后重新探测并确认。';
        invalidatePlan();
        await loadConfig();
        return false;
      }
      handleError(cause, '保存域名草稿失败。');
      return false;
    } finally {
      busy.value = null;
    }
  }

  async function startProbe(managementToken?: string): Promise<boolean> {
    if (!config.value) return false;
    error.value = null;
    notice.value = null;
    busy.value = 'probe';
    probeKey ??= uuid();
    try {
      const next = await api.startProbe(
        config.value.version,
        probeKey,
        managementToken || undefined,
      );
      applyTaskAndStream(next);
      probeKey = null;
      return true;
    } catch (cause) {
      if (cause instanceof AdminApiError && cause.status === 409) {
        error.value = '已有任务占用当前配置目标，已读取当前任务。';
        await loadCurrentTask();
        return false;
      }
      handleError(cause, '启动探测失败。');
      return false;
    } finally {
      busy.value = null;
    }
  }

  async function requestPlan(action: Action): Promise<boolean> {
    if (!config.value || !task.value) return false;
    if (!task.value.allowed_actions.includes(action)) return false;
    error.value = null;
    notice.value = null;
    busy.value = 'plan';
    try {
      const next = await api.createPlan(config.value.version, task.value.task_id, action);
      if (next.config_version !== config.value.version) {
        error.value = '计划对应版本与当前配置不一致，请重新探测。';
        return false;
      }
      plan.value = next;
      return true;
    } catch (cause) {
      handleError(cause, '创建执行计划失败。');
      return false;
    } finally {
      busy.value = null;
    }
  }

  function cancelPlan(): void {
    plan.value = null;
  }

  function planExpired(next: ActionPlan): boolean {
    return next.expires_at * 1000 <= now();
  }

  async function confirmPlan(managementToken?: string): Promise<boolean> {
    const currentPlan = plan.value;
    if (!currentPlan) return false;
    if (busy.value === 'execute') return false; // Double click: one request.
    if (!config.value || currentPlan.config_version !== config.value.version) {
      invalidatePlan('配置已变更，原确认计划不可执行，请重新探测。');
      return false;
    }
    if (planExpired(currentPlan)) {
      invalidatePlan('确认计划已过期，请重新探测。');
      return false;
    }
    error.value = null;
    busy.value = 'execute';
    // Contract PlanExecute.idempotency_key is a UUID. One UUID per plan is
    // cached for this page session so a failed/retried request and a double
    // click reuse the same key; a different plan gets a different UUID.
    let key = executeKeys.get(currentPlan.plan_id);
    if (!key) {
      key = uuid();
      executeKeys.set(currentPlan.plan_id, key);
    }
    try {
      const next = await api.executePlan(currentPlan, key, managementToken || undefined);
      plan.value = null;
      applyTaskAndStream(next);
      return true;
    } catch (cause) {
      if (cause instanceof AdminApiError && cause.status === 409) {
        plan.value = null;
        error.value = '计划或配置已变化，服务端拒绝了本次执行；请重新探测并确认。';
        await loadCurrentTask();
        return false;
      }
      handleError(cause, '执行计划失败。');
      return false;
    } finally {
      busy.value = null;
    }
  }

  function openAuthorizationPrompt(): void {
    authorizationPrompt.value = true;
  }

  function closeAuthorizationPrompt(): void {
    authorizationPrompt.value = false;
  }

  async function authorizeTask(managementToken: string): Promise<boolean> {
    if (!task.value || !managementToken) return false;
    error.value = null;
    busy.value = 'authorize';
    try {
      const next = await api.authorizeTask(task.value.task_id, managementToken);
      authorizationPrompt.value = false;
      applyTaskAndStream(next);
      return true;
    } catch (cause) {
      if (cause instanceof AdminApiError && cause.status === 409) {
        authorizationPrompt.value = false;
        error.value = '该任务已结束或无需授权，已刷新当前任务。';
        await loadCurrentTask();
        return false;
      }
      handleError(cause, '补充管理凭据失败。');
      return false;
    } finally {
      busy.value = null;
    }
  }

  function setUnauthorizedHandler(handler: (() => void) | null) {
    unauthorizedHandler.value = handler;
  }

  const authenticated = computed(() => session.value !== null);
  const mustChangePassword = computed(() => session.value?.must_change_password ?? false);
  const planOpen = computed(() => plan.value !== null);
  const activeTask = computed(() => task.value);
  const streamDisconnected = computed(() => streamState.value === 'error');

  function reset(): void {
    clearSession();
    error.value = null;
    notice.value = null;
    stageBUnavailable.value = false;
  }

  return {
    // state
    session,
    config,
    task,
    plan,
    error,
    notice,
    stageBUnavailable,
    configState,
    taskState,
    streamState,
    busy,
    restoring,
    authorizationPrompt,
    authenticated,
    mustChangePassword,
    planOpen,
    activeTask,
    streamDisconnected,
    // actions
    restoreSession,
    login,
    changePassword,
    logout,
    loadConfig,
    loadCurrentTask,
    refreshWorkspace,
    saveDomain,
    startProbe,
    requestPlan,
    cancelPlan,
    confirmPlan,
    invalidatePlan,
    openAuthorizationPrompt,
    closeAuthorizationPrompt,
    authorizeTask,
    setUnauthorizedHandler,
    closeTaskStream,
    reset,
  };
}

export type AdminState = ReturnType<typeof createAdminState>;
