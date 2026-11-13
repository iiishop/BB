<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useAdminState } from '../stores/context';

const state = useAdminState();
const { busy, error, mustChangePassword } = state;
const router = useRouter();

const oldPassword = ref('');
const newPassword = ref('');
const confirmPassword = ref('');
const localError = ref<string | null>(null);

const ruleHint = computed(() =>
  mustChangePassword
    ? '首次登录只能修改初始密码；完成后所有会话失效，需重新登录。'
    : '修改密码需要当前密码；完成后所有会话失效，需重新登录。',
);

function validate(): string | null {
  if (!oldPassword.value) return '请输入当前密码。';
  if (newPassword.value.length < 12) return '新密码至少 12 个字符（保留空格，不自动裁剪）。';
  if (newPassword.value.length > 1024) return '新密码不能超过 1024 个字符。';
  if (newPassword.value === oldPassword.value) return '新密码不能与当前密码相同。';
  if (newPassword.value !== confirmPassword.value) return '两次输入的新密码不一致。';
  return null;
}

async function submit() {
  localError.value = validate();
  if (localError.value) return;
  const ok = await state.changePassword(oldPassword.value, newPassword.value);
  oldPassword.value = '';
  newPassword.value = '';
  confirmPassword.value = '';
  if (ok) await router.push({ name: 'login' });
}
</script>

<template>
  <div class="auth-card">
    <header class="stack">
      <div class="auth-card__brand">
        <span class="brand__mark" aria-hidden="true">BB</span>
        <span class="brand__meta">Local management</span>
      </div>
      <h1 class="auth-title">修改管理员密码</h1>
      <p class="auth-lede">{{ ruleHint }}</p>
    </header>

    <p v-if="error" class="banner banner--danger" role="alert">
      <span class="banner__icon" aria-hidden="true">!</span>
      <span class="banner__body">{{ error }}</span>
    </p>
    <p v-if="localError" class="banner banner--danger" role="alert">
      <span class="banner__icon" aria-hidden="true">!</span>
      <span class="banner__body">{{ localError }}</span>
    </p>

    <form class="auth-form" novalidate @submit.prevent="submit">
      <label class="field">
        <span>当前密码</span>
        <input
          v-model="oldPassword"
          class="input"
          type="password"
          autocomplete="current-password"
          :disabled="busy === 'password'"
        />
      </label>
      <label class="field">
        <span>新密码</span>
        <input
          v-model="newPassword"
          class="input"
          type="password"
          autocomplete="new-password"
          :disabled="busy === 'password'"
        />
        <span class="field__hint">12–1024 个字符，至少包含一个空格也可保留。</span>
      </label>
      <label class="field">
        <span>再次输入新密码</span>
        <input
          v-model="confirmPassword"
          class="input"
          type="password"
          autocomplete="new-password"
          :disabled="busy === 'password'"
        />
      </label>
      <button type="submit" class="btn" :disabled="busy === 'password'">
        {{ busy === 'password' ? '正在修改…' : '修改密码并退出所有会话' }}
      </button>
    </form>

    <p class="auth-foot">
      密码以带盐 Argon2id 哈希保存。修改成功后不会自动登录；旧密码与旧会话立即失效，冷启动后仍保持。
    </p>
  </div>
</template>
