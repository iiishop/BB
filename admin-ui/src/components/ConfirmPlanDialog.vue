<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue';
import type { ActionPlan } from '../api/types';
import type { BusyAction } from '../stores/admin-state';

const props = defineProps<{
  plan: ActionPlan;
  busy: BusyAction;
}>();

const emit = defineEmits<{
  confirm: [managementToken?: string];
  cancel: [];
}>();

const acknowledged = ref(false);
const managementToken = ref('');
const panel = ref<HTMLElement | null>(null);
let previousFocus: HTMLElement | null = null;

const resourceKindLabels = {
  package: '系统软件',
  service: '系统服务',
  tunnel: 'Tunnel',
  dns: 'DNS 路由',
} as const;
const operationLabels = { create: '新建', reuse: '复用' } as const;

const expiry = computed(() =>
  new Date(props.plan.expires_at * 1000).toLocaleString('zh-CN', {
    hour12: false,
  }),
);
const shortDigest = computed(() => props.plan.digest.slice(0, 12));

function cancel() {
  emit('cancel');
}

function confirm() {
  if (!acknowledged.value || props.busy !== null) return;
  emit('confirm', managementToken.value.trim() || undefined);
  managementToken.value = '';
}

function onKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape') {
    event.preventDefault();
    cancel();
    return;
  }
  if (event.key !== 'Tab' || !panel.value) return;
  const focusable = panel.value.querySelectorAll<HTMLElement>(
    'button:not([disabled]), input:not([disabled]), [href], select, textarea',
  );
  if (focusable.length === 0) return;
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus();
  }
}

onMounted(async () => {
  previousFocus = document.activeElement as HTMLElement | null;
  document.addEventListener('keydown', onKeydown);
  document.body.style.overflow = 'hidden';
  await nextTick();
  panel.value?.focus();
});

onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKeydown);
  document.body.style.overflow = '';
  managementToken.value = '';
  previousFocus?.focus?.();
});
</script>

<template>
  <Teleport to="body">
    <div class="overlay" @click.self="cancel">
      <div
        ref="panel"
        class="dialog"
        tabindex="-1"
        role="dialog"
        aria-modal="true"
        aria-labelledby="plan-dialog-title"
        aria-describedby="plan-dialog-lede"
      >
        <header class="dialog__header">
          <h2 id="plan-dialog-title" class="dialog__title">确认公网执行计划</h2>
          <p id="plan-dialog-lede" class="dialog__lede">
            只有确认下方这一份计划后才会执行。计划绑定当前配置版本与目标，任一变化都会使确认失效。
          </p>
        </header>

        <div class="dialog__body">
        <section class="dialog__section">
          <span class="dialog__label">域名</span>
          <span class="dialog__value">{{ plan.domain }}</span>
        </section>

        <section class="dialog__section">
          <span class="dialog__label">目标服务（服务端选择）</span>
          <span class="dialog__value mono">{{ plan.target_service }}</span>
        </section>

        <section class="dialog__section">
          <span class="dialog__label">将创建或复用的资源</span>
          <ul class="dialog__list">
            <li v-for="(resource, index) in plan.resources" :key="`${resource.kind}-${index}`">
              <span>
                {{ resourceKindLabels[resource.kind] }} ·
                {{ operationLabels[resource.operation] }} ·
                <code>{{ resource.name }}</code>
              </span>
            </li>
          </ul>
        </section>

        <section class="dialog__section">
          <span class="dialog__label">公开范围</span>
          <ul class="dialog__list">
            <li v-for="scope in plan.public_scope" :key="scope">{{ scope }}</li>
          </ul>
        </section>

        <section class="dialog__section dialog__risk">
          <span class="dialog__label">风险</span>
          <ul class="dialog__list">
            <li v-for="risk in plan.risks" :key="risk">{{ risk }}</li>
          </ul>
        </section>

        <section class="dialog__section">
          <label class="field">
            <span>管理 API Token（可选，仅本机提交）</span>
            <input
              v-model="managementToken"
              class="input"
              type="password"
              autocomplete="off"
              spellcheck="false"
              placeholder="仅在服务端要求补充时填写"
            />
            <span class="field__hint">
              凭据不回显、不写入浏览器存储，也不进入计划摘要。Tunnel 运行 token 不是管理凭据。
            </span>
          </label>
        </section>

        <label class="dialog__checkbox">
          <input v-model="acknowledged" type="checkbox" />
          <span>我已核对域名、目标服务、资源与公开范围，并确认执行这份计划。</span>
        </label>

        <p class="dialog__footnote">
          计划 {{ shortDigest }} · 配置 v{{ plan.config_version }} · 有效期至 {{ expiry }}。
          确认不代表 Cloudflare 账号授权、sudo/UAC 或后续修改的授权。
        </p>
        </div>

        <footer class="dialog__footer">
          <button
            type="button"
            class="btn btn--secondary"
            :disabled="busy !== null"
            @click="cancel"
          >
            取消
          </button>
          <button
            type="button"
            class="btn"
            :disabled="!acknowledged || busy !== null"
            @click="confirm"
          >
            {{ busy === 'execute' ? '正在提交…' : '确认并执行' }}
          </button>
        </footer>
      </div>
    </div>
  </Teleport>
</template>
