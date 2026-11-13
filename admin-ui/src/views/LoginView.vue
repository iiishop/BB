<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAdminState } from '../stores/context';

const state = useAdminState();
const { busy, error, notice } = state;
const router = useRouter();
const route = useRoute();

const username = ref('admin');
const password = ref('');
const localError = ref<string | null>(null);

const expired = computed(() => route.query.expired === '1');

async function submit() {
  localError.value = null;
  if (!username.value.trim() || !password.value) {
    localError.value = '请输入管理员用户名和密码。';
    return;
  }
  const ok = await state.login(username.value.trim(), password.value);
  password.value = '';
  if (!ok) return;
  await router.push({
    name: state.mustChangePassword.value ? 'change-password' : 'home',
  });
}
</script>

<template>
  <div class="auth-card">
    <header class="stack">
      <div class="auth-card__brand">
        <span class="brand__mark" aria-hidden="true">BB</span>
        <span class="brand__meta">Local management</span>
      </div>
      <h1 class="auth-title">管理员登录</h1>
      <p class="auth-lede">
        仅限本机管理入口 <code>127.0.0.1</code>。管理员身份独立于普通 BB 用户。
      </p>
    </header>

    <p v-if="expired" class="banner banner--warning" role="alert">
      <span class="banner__icon" aria-hidden="true">!</span>
      <span class="banner__body">会话已过期或已失效，请重新登录。</span>
    </p>
    <p v-if="notice" class="banner banner--success" role="status">
      <span class="banner__icon" aria-hidden="true">✓</span>
      <span class="banner__body">{{ notice }}</span>
    </p>
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
        <span>用户名</span>
        <input
          v-model="username"
          class="input"
          type="text"
          name="username"
          autocomplete="username"
          spellcheck="false"
          :disabled="busy === 'login'"
        />
      </label>
      <label class="field">
        <span>密码</span>
        <input
          v-model="password"
          class="input"
          type="password"
          name="password"
          autocomplete="current-password"
          :disabled="busy === 'login'"
        />
      </label>
      <button type="submit" class="btn" :disabled="busy === 'login'">
        {{ busy === 'login' ? '正在登录…' : '登录' }}
      </button>
    </form>

    <p class="auth-foot">
      新实例初始凭据为 <code>admin/admin</code>，首次登录必须修改密码。连续失败的登录尝试共用每分钟 5 次的持久化额度。
    </p>
  </div>
</template>
