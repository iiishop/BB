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
  const domainDraft = ref<string | null>(null);
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
  // Every accepted task snapshot advances the authority epoch. A
  // /tasks/current read that started before it is stale and must not replace
  // the newer task or close its stream. Task ids alone are not an ordering rule.
  let taskEpoch = 0;
  let taskReadSerial = 0;
  let streamSerial = 0;
  let sessionEpoch = 0;
  let busySerial = 0;
  let busyOwner: number | null = null;
  let restoringSerial = 0;
  let restoringOwner: number | null = null;

  function setCsrf(value: string | null) {
    csrfToken = value;
  }

  function closeTaskStream() {
    streamSerial += 1;
    closeStream?.();
    closeStream = null;
    streamState.value = 'idle';
  }

  function applySession(next: AdminSession | null) {
    sessionEpoch += 1;
    session.value = next;
    setCsrf(next?.csrf_token ?? null);
  }

  function sessionStillCurrent(epoch: number): boolean {
    return epoch === sessionEpoch;
  }

  function taskResponseStillOwned(ownerTaskId: string | null): boolean {
    const current = task.value;
    return ownerTaskId === null ? current === null : current?.task_id === ownerTaskId;
  }

  function beginBusy(action: Exclude<BusyAction, null>): number {
    const token = ++busySerial;
    busyOwner = token;
    busy.value = action;
    return token;
  }

  function endBusy(token: number) {
    if (busyOwner === token) {
      busyOwner = null;
      busy.value = null;
    }
  }

  function beginRestoring(): number {
    const token = ++restoringSerial;
    restoringOwner = token;
    restoring.value = true;
    return token;
  }

  function endRestoring(token: number) {
    if (restoringOwner === token) {
      restoringOwner = null;
      restoring.value = false;
    }
  }

  function clearSession(noticeText?: string) {
    applySession(null);
    closeTaskStream();
    executeKeys.clear();
    config.value = null;
    domainDraft.value = null;
    task.value = null;
    plan.value = null;
    authorizationPrompt.value = false;
    busyOwner = null;
    busy.value = null;
    restoringOwner = null;
    restoring.value = false;
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

  type ConfigApply = 'newer' | 'same' | 'stale';

  function applyConfig(next: PublicConfig): ConfigApply {
    const previous = config.value;
    if (previous && next.version < previous.version) return 'stale';
    if (previous && next.version === previous.version) {
      // Active verification does not bump the draft version. Accept a newer
      // active snapshot at the same version, but never let a same-version
      // response roll back the domain or an already verified active config.
      if (next.domain !== previous.domain) return 'stale';
      if (
        next.active &&
        (!previous.active || next.active.verified_at >= previous.active.verified_at)
      ) {
        config.value = { ...previous, active: next.active };
        configState.value = 'ready';
      }
      return 'same';
    }
    config.value = next;
    configState.value = 'ready';
    if (domainDraft.value !== null && domainDraft.value === next.domain) {
      domainDraft.value = null;
    }
    if (previous) invalidatePlan();
    return 'newer';
  }

  function applyTask(next: AdminTask): boolean {
    const current = task.value;
    if (current && current.task_id === next.task_id && next.seq < current.seq) {
      return false; // Duplicate/older sequence: keep the newest snapshot.
    }
    task.value = next;
    taskState.value = 'ready';
    taskEpoch += 1;
    if (next.stage === 'finished') {
      closeTaskStream();
      probeKey = null;
    }
    return true;
  }

  function streamTask(nextTask: AdminTask) {
    closeTaskStream();
    if (nextTask.stage === 'finished') return;
    const serial = ++streamSerial;
    streamState.value = 'connecting';
    const handlers: TaskStreamHandlers = {
      onTask: (eventTask) => {
        // A closed/replaced EventSource can still deliver a queued callback.
        // Only the stream that currently owns delivery may update the store.
        if (serial !== streamSerial) return;
        applyTask(eventTask);
      },
      onStateChange: (state) => {
        if (serial !== streamSerial) return;
        streamState.value = state;
      },
    };
    closeStream = api.subscribeTask(nextTask.task_id, nextTask.seq, handlers);
  }

  function applyTaskAndStream(next: AdminTask) {
    const accepted = applyTask(next);
    if (accepted && isNonTerminalTask(next)) streamTask(next);
  }

  function invalidatePlan(reason?: string) {
    if (!plan.value) return;
    plan.value = null;
    notice.value = reason ?? '确认计划已失效，请重新探测并确认。';
  }

  async function restoreSession(): Promise<boolean> {
    const epoch = sessionEpoch;
    const restoreToken = beginRestoring();
    try {
      const next = await api.session();
      if (!sessionStillCurrent(epoch)) return false;
      applySession(next);
      return true;
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return false;
      if (cause instanceof AdminApiError && cause.isUnauthenticated) {
        clearSession();
      } else {
        error.value = messageOf(cause);
      }
      return false;
    } finally {
      endRestoring(restoreToken);
    }
  }

  async function login(username: string, password: string): Promise<boolean> {
    error.value = null;
    notice.value = null;
    const busyToken = beginBusy('login');
    const epoch = sessionEpoch;
    try {
      const next = await api.login(username, password);
      if (!sessionStillCurrent(epoch)) return false;
      applySession(next);
      return true;
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return false;
      // A 401 from /login means wrong credentials, not an expired session:
      // keep the form and never redirect through the session-expiry path.
      if (cause instanceof AdminApiError && (cause.isUnauthenticated || cause.status === 429)) {
        error.value = cause.message;
      } else {
        handleError(cause, '无法连接本机管理入口，请确认 bb-admin 正在运行。');
      }
      return false;
    } finally {
      endBusy(busyToken);
    }
  }

  async function changePassword(oldPassword: string, newPassword: string): Promise<boolean> {
    error.value = null;
    const busyToken = beginBusy('password');
    const epoch = sessionEpoch;
    try {
      await api.changePassword(oldPassword, newPassword);
      if (!sessionStillCurrent(epoch)) return false;
      clearSession('密码已修改，所有旧会话已失效，请用新密码重新登录。');
      return true;
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return false;
      handleError(cause, '修改密码失败，请重试。');
      return false;
    } finally {
      endBusy(busyToken);
    }
  }

  async function logout(): Promise<void> {
    const epoch = sessionEpoch;
    const busyToken = beginBusy('logout');
    try {
      await api.logout();
    } catch (cause) {
      if (
        sessionStillCurrent(epoch) &&
        !(cause instanceof AdminApiError && cause.isUnauthenticated)
      ) {
        // Logout still clears local state; report rather than block exit.
        error.value = messageOf(cause);
      }
    } finally {
      if (sessionStillCurrent(epoch)) clearSession();
      endBusy(busyToken);
    }
  }

  async function loadConfig(): Promise<void> {
    const epoch = sessionEpoch;
    configState.value = 'loading';
    try {
      const next = await api.getPublicConfig();
      if (!sessionStillCurrent(epoch)) return;
      applyConfig(next);
      stageBUnavailable.value = false;
      configState.value = 'ready';
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return;
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
    const request = ++taskReadSerial;
    const startedAt = taskEpoch;
    const epoch = sessionEpoch;
    taskState.value = 'loading';
    try {
      const current = await api.currentTask();
      // A new session (login/logout) invalidates this response completely.
      if (!sessionStillCurrent(epoch)) return;
      // A newer task was adopted (mutation/SSE) or a newer read started while
      // this one was in flight: this snapshot is stale and owns nothing.
      if (request !== taskReadSerial || startedAt !== taskEpoch) return;
      stageBUnavailable.value = false;
      if (current.task) {
        applyTaskAndStream(current.task);
      } else {
        closeTaskStream();
        task.value = null;
        taskState.value = 'ready';
      }
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return;
      if (cause instanceof AdminApiError && cause.isUnauthenticated) {
        handleUnauthorized();
        taskState.value = 'error';
        return;
      }
      if (request !== taskReadSerial || startedAt !== taskEpoch) return;
      if (cause instanceof AdminApiError && cause.isStageBUnavailable) {
        stageBUnavailable.value = true;
        task.value = null;
        taskState.value = 'unavailable';
        return;
      }
      handleError(cause, '读取当前任务失败。');
      taskState.value = 'error';
    }
  }

  async function refreshWorkspace(): Promise<void> {
    await Promise.all([loadConfig(), loadCurrentTask()]);
  }

  function setDomainDraft(value: string) {
    domainDraft.value = value === (config.value?.domain ?? '') ? null : value;
    if (domainDraft.value !== null) {
      invalidatePlan('域名草稿已修改，原确认计划已失效；请先保存并重新探测。');
    }
  }

  function discardDomainDraft() {
    domainDraft.value = null;
  }

  async function saveDomain(domain?: string): Promise<boolean> {
    if (!config.value) return false;
    const value = (domain ?? domainDraft.value ?? config.value.domain ?? '').trim();
    if (!value) return false;
    error.value = null;
    notice.value = null;
    const busyToken = beginBusy('save');
    const epoch = sessionEpoch;
    try {
      const hadPlan = plan.value !== null;
      const next = await api.savePublicConfig(config.value.version, value);
      if (!sessionStillCurrent(epoch)) return false;
      // A refresh may already have observed this successful write. Confirm
      // the same snapshot without replacing newer active verification data.
      if (applyConfig(next) === 'stale') {
        error.value =
          '另一个配置更新已生效，本次较早的保存响应未覆盖当前页面；请刷新核对。';
        return false;
      }
      domainDraft.value = null;
      notice.value = hadPlan
        ? '域名已保存为草稿，原确认计划已失效；请重新探测并确认后才会生效。'
        : '域名已保存为草稿；需要重新探测、计划并确认后才会生效。';
      return true;
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return false;
      if (cause instanceof AdminApiError && cause.status === 409) {
        error.value = '配置版本已变化，请刷新后重新探测并确认。';
        invalidatePlan();
        await loadConfig();
        return false;
      }
      handleError(cause, '保存域名草稿失败。');
      return false;
    } finally {
      endBusy(busyToken);
    }
  }

  async function startProbe(managementToken?: string): Promise<boolean> {
    if (!config.value) return false;
    if (draftDirty.value) {
      error.value = '域名草稿尚未保存；请先保存或放弃草稿，再运行探测。';
      return false;
    }
    error.value = null;
    notice.value = null;
    const busyToken = beginBusy('probe');
    const ownerTaskId = task.value?.task_id ?? null;
    const epoch = sessionEpoch;
    probeKey ??= uuid();
    try {
      const next = await api.startProbe(
        config.value.version,
        probeKey,
        managementToken || undefined,
      );
      if (!sessionStillCurrent(epoch)) return false;
      if (!taskResponseStillOwned(ownerTaskId)) {
        notice.value = '已有更新任务，较早的探测响应未覆盖当前任务。';
        return false;
      }
      applyTaskAndStream(next);
      probeKey = null;
      return true;
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return false;
      if (cause instanceof AdminApiError && cause.status === 409) {
        error.value = '已有任务占用当前配置目标，已读取当前任务。';
        await loadCurrentTask();
        return false;
      }
      handleError(cause, '启动探测失败。');
      return false;
    } finally {
      endBusy(busyToken);
    }
  }

  async function requestPlan(action: Action): Promise<boolean> {
    if (!config.value || !task.value) return false;
    if (draftDirty.value) {
      error.value =
        '域名草稿尚未保存；请先保存或放弃草稿并重新探测，再生成执行计划。';
      return false;
    }
    if (task.value.config_version !== config.value.version) {
      error.value = `探测任务属于配置 v${task.value.config_version}，当前配置为 v${config.value.version}；请重新探测后再生成计划。`;
      return false;
    }
    if (!task.value.allowed_actions.includes(action)) return false;
    error.value = null;
    notice.value = null;
    const busyToken = beginBusy('plan');
    const ownerTaskId = task.value.task_id;
    const epoch = sessionEpoch;
    try {
      const next = await api.createPlan(config.value.version, ownerTaskId, action);
      if (!sessionStillCurrent(epoch)) return false;
      if (!taskResponseStillOwned(ownerTaskId)) {
        error.value = '任务已被更新，较早的计划响应未覆盖当前任务；请重新探测。';
        return false;
      }
      if (next.config_version !== config.value.version) {
        error.value = '计划对应版本与当前配置不一致，请重新探测。';
        return false;
      }
      plan.value = next;
      return true;
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return false;
      handleError(cause, '创建执行计划失败。');
      return false;
    } finally {
      endBusy(busyToken);
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
    if (draftDirty.value) {
      invalidatePlan('域名草稿有未保存修改，原确认计划不可执行；请先保存或放弃草稿。');
      return false;
    }
    if (!config.value || currentPlan.config_version !== config.value.version) {
      invalidatePlan('配置已变更，原确认计划不可执行，请重新探测。');
      return false;
    }
    if (planExpired(currentPlan)) {
      invalidatePlan('确认计划已过期，请重新探测。');
      return false;
    }
    error.value = null;
    const busyToken = beginBusy('execute');
    // Contract PlanExecute.idempotency_key is a UUID. One UUID per plan is
    // cached for this page session so a failed/retried request and a double
    // click reuse the same key; a different plan gets a different UUID.
    let key = executeKeys.get(currentPlan.plan_id);
    if (!key) {
      key = uuid();
      executeKeys.set(currentPlan.plan_id, key);
    }
    const ownerTaskId = task.value?.task_id ?? null;
    const epoch = sessionEpoch;
    try {
      const next = await api.executePlan(currentPlan, key, managementToken || undefined);
      if (!sessionStillCurrent(epoch)) return false;
      if (!taskResponseStillOwned(ownerTaskId)) {
        plan.value = null;
        notice.value = '任务已被更新，较早的执行响应未覆盖当前任务；请刷新核对。';
        return false;
      }
      plan.value = null;
      applyTaskAndStream(next);
      return true;
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return false;
      if (cause instanceof AdminApiError && cause.status === 409) {
        plan.value = null;
        error.value = '计划或配置已变化，服务端拒绝了本次执行；请重新探测并确认。';
        await loadCurrentTask();
        return false;
      }
      handleError(cause, '执行计划失败。');
      return false;
    } finally {
      endBusy(busyToken);
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
    const ownerTaskId = task.value.task_id;
    const epoch = sessionEpoch;
    error.value = null;
    const busyToken = beginBusy('authorize');
    try {
      const next = await api.authorizeTask(ownerTaskId, managementToken);
      if (!sessionStillCurrent(epoch)) return false;
      if (!taskResponseStillOwned(ownerTaskId)) {
        authorizationPrompt.value = false;
        notice.value = '任务已被更新，较早的授权响应未覆盖当前任务；请刷新核对。';
        return false;
      }
      authorizationPrompt.value = false;
      applyTaskAndStream(next);
      return true;
    } catch (cause) {
      if (!sessionStillCurrent(epoch)) return false;
      if (cause instanceof AdminApiError && cause.status === 409) {
        authorizationPrompt.value = false;
        error.value = '该任务已结束或无需授权，已刷新当前任务。';
        await loadCurrentTask();
        return false;
      }
      handleError(cause, '补充管理凭据失败。');
      return false;
    } finally {
      endBusy(busyToken);
    }
  }

  function setUnauthorizedHandler(handler: (() => void) | null) {
    unauthorizedHandler.value = handler;
  }

  const draftDirty = computed(
    () => domainDraft.value !== null && domainDraft.value !== (config.value?.domain ?? ''),
  );
  const taskVersionStale = computed(
    () =>
      task.value !== null &&
      config.value !== null &&
      task.value.config_version !== config.value.version,
  );
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
    domainDraft,
    draftDirty,
    taskVersionStale,
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
    setDomainDraft,
    discardDomainDraft,
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
