<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref } from 'vue';
import type { BusyAction } from '../stores/admin-state';

defineProps<{
  busy: BusyAction;
  message?: string;
}>();

const emit = defineEmits<{
  submit: [managementToken: string];
  cancel: [];
}>();

const token = ref('');
const input = ref<HTMLInputElement | null>(null);
const panel = ref<HTMLElement | null>(null);
let previousFocus: HTMLElement | null = null;

function submit() {
  const value = token.value.trim();
  if (!value) return;
  emit('submit', value);
  token.value = '';
}

function cancel() {
  token.value = '';
  emit('cancel');
}

function onKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape') {
    event.preventDefault();
    cancel();
    return;
  }
  if (event.key !== 'Tab' || !panel.value) return;
  const focusable = panel.value.querySelectorAll<HTMLElement>(
    'button:not([disabled]), input:not([disabled]), [href]',
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
  input.value?.focus();
});

onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKeydown);
  document.body.style.overflow = '';
  token.value = '';
  previousFocus?.focus?.();
});
</script>

<template>
  <Teleport to="body">
    <div class="overlay" @click.self="cancel">
      <div
        ref="panel"
        class="dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="auth-dialog-title"
        aria-describedby="auth-dialog-lede"
      >
        <header class="dialog__header">
          <h2 id="auth-dialog-title" class="dialog__title">补充管理凭据</h2>
          <p id="auth-dialog-lede" class="dialog__lede">
            该任务需要 Cloudflare 管理权限。请提供最小权限 API Token；凭据只发送到本机管理入口，不保存、不回显。
          </p>
        </header>

        <p v-if="message" class="banner banner--info">
          <span class="banner__icon" aria-hidden="true">i</span>
          <span class="banner__body">{{ message }}</span>
        </p>

        <label class="field">
          <span>管理 API Token</span>
          <input
            ref="input"
            v-model="token"
            class="input"
            type="password"
            autocomplete="off"
            spellcheck="false"
            placeholder="粘贴最小权限 API Token"
          />
          <span class="field__hint">
            运行 Tunnel 的 token 不是管理凭据；此处输入不会改变已确认的计划，也不会被当作账号授权。
          </span>
        </label>

        <footer class="dialog__footer">
          <button type="button" class="btn btn--secondary" :disabled="busy !== null" @click="cancel">
            取消
          </button>
          <button
            type="button"
            class="btn"
            :disabled="!token.trim() || busy !== null"
            @click="submit"
          >
            {{ busy === 'authorize' ? '正在提交…' : '提交凭据并恢复任务' }}
          </button>
        </footer>
      </div>
    </div>
  </Teleport>
</template>
