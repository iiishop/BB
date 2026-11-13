<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import type { Action, Classification } from '../api/types';
import ConfirmPlanDialog from '../components/ConfirmPlanDialog.vue';
import StatusCapsule from '../components/StatusCapsule.vue';
import TokenPromptDialog from '../components/TokenPromptDialog.vue';
import { CHECK_LABELS, CLASSIFICATION_LABELS } from '../lib/labels';
import { useAdminState } from '../stores/context';

const state = useAdminState();
const {
  config,
  draftDirty,
  taskVersionStale,
  task,
  plan,
  error,
  notice,
  stageBUnavailable,
  configState,
  taskState,
  busy,
  authorizationPrompt,
  streamState,
} = state;

const localAdminNotice = ref(false);

const domainDraft = computed({
  get: () => state.domainDraft.value ?? config.value?.domain ?? '',
  set: (value: string) => state.setDomainDraft(value),
});

watch(
  () => task.value?.stage,
  (stage) => {
    if (stage === 'finished' && task.value?.classification === 'passed' && !stageBUnavailable.value) {
      void state.loadConfig();
    }
  },
);

onMounted(() => {
  void state.refreshWorkspace();
});

const canEdit = computed(() => config.value !== null && !stageBUnavailable.value);
const canProbe = computed(
  () =>
    config.value !== null &&
    !stageBUnavailable.value &&
    !draftDirty.value &&
    busy.value === null,
);
const active = computed(() => config.value?.active ?? null);

const classifications: Record<Classification, string> = CLASSIFICATION_LABELS;

function chipTone(classification: Classification): string {
  if (classification === 'failed') return 'failed';
  if (classification === 'unknown') return 'unknown';
  if (classification === 'passed') return 'passed';
  return 'running';
}

function formatTime(seconds: number): string {
  return new Date(seconds * 1000).toLocaleString('zh-CN', { hour12: false });
}

function formatSeq(seq: number): string {
  return `#${seq}`;
}

async function saveDomain() {
  if (!domainDraft.value.trim()) return;
  localAdminNotice.value = false;
  await state.saveDomain();
}

async function probe() {
  localAdminNotice.value = false;
  await state.startProbe();
}

async function onCapsuleAction(action: Action) {
  localAdminNotice.value = false;
  if (action === 'authorize') {
    state.openAuthorizationPrompt();
    return;
  }
  if (action === 'local_admin') {
    localAdminNotice.value = true;
    return;
  }
  await state.requestPlan(action);
}

async function onConfirm(managementToken?: string) {
  await state.confirmPlan(managementToken);
}

async function onAuthorize(managementToken: string) {
  await state.authorizeTask(managementToken);
}
</script>

<template>
  <div class="page">
    <header class="page-header">
      <span class="eyebrow">公网接入</span>
      <h1 class="page-title">配置</h1>
      <p class="page-lede">
        先保存专用子域名草稿，再运行只读探测。安装、创建 Tunnel 与 DNS 路由等有副作用的步骤只在确认具体计划后执行。
      </p>
      <div class="actions">
        <button
          type="button"
          class="btn btn--quiet"
          :disabled="configState === 'loading' || taskState === 'loading'"
          @click="state.refreshWorkspace()"
        >
          刷新当前状态
        </button>
      </div>
    </header>

    <p v-if="stageBUnavailable" class="banner banner--info" role="status">
      <span class="banner__icon" aria-hidden="true">i</span>
      <span class="banner__body">
        <strong class="banner__title">阶段 B 尚未接通</strong>
        <span class="banner__text">
          当前服务端返回 <code>501 stage_b_not_implemented</code>：公网草稿、探测、计划与执行仍为保留契约，页面不会产生任何外部副作用。以下控件为契约预览，待阶段 B 服务端接通后可操作。
        </span>
      </span>
    </p>

    <p v-if="error" class="banner banner--danger" role="alert">
      <span class="banner__icon" aria-hidden="true">!</span>
      <span class="banner__body">{{ error }}</span>
    </p>
    <p v-if="notice" class="banner banner--success" role="status">
      <span class="banner__icon" aria-hidden="true">✓</span>
      <span class="banner__body">{{ notice }}</span>
    </p>
    <p v-if="localAdminNotice" class="banner banner--warning" role="status">
      <span class="banner__icon" aria-hidden="true">!</span>
      <span class="banner__body">
        <strong class="banner__title">需要本机管理员操作</strong>
        <span class="banner__text">
          该步骤不能由浏览器执行。请在本机管理员终端完成固定操作（例如安装系统软件或注册服务），然后重新运行探测。BB 常驻进程不以 root/管理员身份运行；后台无交互桌面时需本机管理员手动完成，不能假定 UAC/sudo 会自动弹窗。
        </span>
      </span>
    </p>

    <section class="card" aria-labelledby="domain-card-title">
      <header class="card__header">
        <div class="stack">
          <h2 id="domain-card-title" class="card__title">域名草稿</h2>
          <span class="card__meta">
            配置版本 v{{ config?.version ?? '—' }} · 草稿保存与已验证生效分开
          </span>
        </div>
        <span v-if="config" class="chip" :class="active ? 'chip--passed' : 'chip--unknown'">
          {{ active ? '已生效' : '尚未生效' }}
        </span>
      </header>

      <div v-if="active" class="stack">
        <dl class="kv">
          <dt>当前生效域名</dt>
          <dd><code>{{ active.domain }}</code></dd>
          <dt>验证时间</dt>
          <dd>{{ formatTime(active.verified_at) }}</dd>
          <dt>Tunnel</dt>
          <dd class="mono">{{ active.tunnel_id }}</dd>
        </dl>
      </div>

      <label class="field">
        <span>专用子域名</span>
        <input
          v-model="domainDraft"
          class="input"
          type="text"
          inputmode="url"
          autocomplete="off"
          spellcheck="false"
          placeholder="bb.example.com"
          :disabled="!canEdit || busy !== null"
          :aria-invalid="false"
        />
        <span class="field__hint">
          仅 ASCII 子域名，例如 <code>bb.example.com</code>。不要输入协议、端口、IP、通配符或真实域名；保存草稿不会改变已生效配置。
        </span>
      </label>

      <div class="actions">
        <button
          type="button"
          class="btn"
          :disabled="!canEdit || busy !== null || !draftDirty || !domainDraft.trim()"
          @click="saveDomain"
        >
          {{ busy === 'save' ? '正在保存…' : '保存域名草稿' }}
        </button>
        <button
          v-if="draftDirty"
          type="button"
          class="btn btn--quiet"
          :disabled="busy !== null"
          @click="state.discardDomainDraft()"
        >
          放弃修改
        </button>
        <span v-if="draftDirty" class="chip chip--unknown">有未保存修改</span>
        <span v-else-if="config" class="chip">草稿已保存</span>
      </div>

      <p v-if="draftDirty" class="banner banner--warning" role="status">
        <span class="banner__icon" aria-hidden="true">!</span>
        <span class="banner__body">
          <strong class="banner__title">域名草稿尚未保存</strong>
          <span class="banner__text">
            探测、计划和执行仍使用已保存配置 v{{ config?.version ?? '—' }}（{{ config?.domain ?? '未保存域名' }}）。请先保存草稿或放弃修改，再继续。
          </span>
        </span>
      </p>

      <p v-if="!active && !stageBUnavailable" class="banner banner--warning" role="status">
        <span class="banner__icon" aria-hidden="true">!</span>
        <span class="banner__body">
          草稿尚未验证生效。只有当前实例的挑战验证通过后，域名才会写入已生效配置。
        </span>
      </p>
    </section>

    <section class="card" aria-labelledby="status-card-title" aria-live="polite">
      <header class="card__header">
        <div class="stack">
          <h2 id="status-card-title" class="card__title">公网连通状态</h2>
          <span class="card__meta">
            安装、服务、连接、授权、路由与实例验证分别判断
            <template v-if="task"> · 任务 {{ formatSeq(task.seq) }}</template>
            <template v-if="streamState === 'error'"> · 实时连接中断</template>
          </span>
        </div>
        <button
          v-if="task && !stageBUnavailable"
          type="button"
          class="btn btn--quiet"
          :disabled="busy !== null"
          @click="probe"
        >
          重新只读探测
        </button>
      </header>

      <template v-if="task">
        <StatusCapsule
          :task="task"
          :busy="busy"
          :planning-disabled="draftDirty || taskVersionStale"
          @action="onCapsuleAction"
        />

        <p v-if="taskVersionStale && !draftDirty" class="banner banner--warning" role="status">
          <span class="banner__icon" aria-hidden="true">!</span>
          <span class="banner__body">
            该任务属于配置 v{{ task.config_version }}，当前配置为 v{{ config?.version }}；请重新探测后再生成执行计划。
          </span>
        </p>

        <p v-if="streamState === 'error'" class="banner banner--warning" role="status">
          <span class="banner__icon" aria-hidden="true">!</span>
          <span class="banner__body">
            实时事件连接中断。页面保留最后一次服务端快照；刷新会从
            <code>/tasks/current</code> 恢复，不会因断线重建任务或重复执行命令。
          </span>
        </p>

        <div v-if="task.checks.length" class="checks">
          <div v-for="check in task.checks" :key="check.check" class="check">
            <div class="check__head">
              <span>{{ CHECK_LABELS[check.check] }}</span>
              <span class="chip" :class="`chip--${chipTone(check.classification)}`">
                {{ classifications[check.classification] }}
              </span>
            </div>
            <p class="check__message">{{ check.message }}</p>
          </div>
        </div>
        <p v-else class="muted small">服务端尚未返回分项检测结果。</p>

        <div v-if="task.resources.length" class="stack">
          <h3 class="card__title">本次任务记录的资源</h3>
          <ul class="resource-list">
            <li v-for="resource in task.resources" :key="resource.resource_id" class="resource">
              <span class="resource__kind">{{ resource.kind }}</span>
              <span class="resource__id mono">{{ resource.resource_id }}</span>
              <span class="chip">
                {{
                  resource.ownership === 'created_by_task'
                    ? '本次创建'
                    : resource.ownership === 'reused'
                      ? '复用'
                      : '归属未知'
                }}
              </span>
            </li>
          </ul>
        </div>

        <dl class="kv">
          <dt>任务 ID</dt>
          <dd class="mono">{{ task.task_id }}</dd>
          <dt>类型 / 版本</dt>
          <dd>{{ task.kind === 'probe' ? '只读探测' : '执行' }} · 配置 v{{ task.config_version }}</dd>
          <dt>问题码</dt>
          <dd><code>{{ task.issue_code ?? '—' }}</code></dd>
          <dt>实时状态</dt>
          <dd>
            {{
              streamState === 'open'
                ? '已连接服务端事件流'
                : streamState === 'connecting'
                  ? '正在连接事件流'
                  : streamState === 'error'
                    ? '已断开，可刷新恢复'
                    : '任务已结束'
            }}
          </dd>
        </dl>
      </template>

      <template v-else-if="stageBUnavailable">
        <section class="capsule">
          <div class="capsule__status">
            <span class="capsule__dot capsule__dot--unknown" aria-hidden="true"></span>
            <div class="capsule__text">
              <div class="capsule__headline">
                <span>公网编排未接通</span>
                <span class="chip chip--unknown">阶段 B 保留</span>
              </div>
              <p class="capsule__message">
                服务端尚未实现探测与任务接口，因此没有可展示的连通状态，也没有允许动作。
              </p>
            </div>
          </div>
        </section>
      </template>

      <template v-else>
        <section class="capsule">
          <div class="capsule__status">
            <span class="capsule__dot" aria-hidden="true"></span>
            <div class="capsule__text">
              <div class="capsule__headline">
                <span>{{ taskState === 'loading' ? '正在读取任务…' : '尚未探测' }}</span>
              </div>
              <p class="capsule__message">
                只读探测会检查 cloudflared 安装、服务、连接、授权与路由状态，不安装、不创建资源。
              </p>
            </div>
          </div>
          <div class="capsule__action">
            <button
              type="button"
              class="btn"
              :disabled="!canProbe || taskState === 'loading'"
              @click="probe"
            >
              {{ busy === 'probe' ? '正在启动…' : '开始只读探测' }}
            </button>
          </div>
        </section>
      </template>
    </section>

    <p class="muted small">
      共享状态由服务端持有：页面刷新、双击与事件流断线都不会新建任务。管理凭据只在本机内存中提交，不写入浏览器存储。
    </p>

    <ConfirmPlanDialog
      v-if="plan"
      :plan="plan"
      :busy="busy"
      @confirm="onConfirm"
      @cancel="state.cancelPlan()"
    />
    <TokenPromptDialog
      v-if="authorizationPrompt"
      :busy="busy"
      :message="task?.message"
      @submit="onAuthorize"
      @cancel="state.closeAuthorizationPrompt()"
    />
  </div>
</template>
