<script setup lang="ts">
import { useRouter } from 'vue-router';
import { useAdminState } from '../stores/context';

const state = useAdminState();
const { session, busy } = state;
const router = useRouter();

async function signOut() {
  await state.logout();
  await router.push({ name: 'login' });
}
</script>

<template>
  <aside class="sidebar">
    <div class="brand">
      <span class="brand__mark" aria-hidden="true">BB</span>
      <span class="brand__text">
        <span class="brand__name">BB 管理</span>
        <span class="brand__meta">Local only</span>
      </span>
    </div>

    <nav class="nav" aria-label="主导航">
      <RouterLink class="nav__link" :to="{ name: 'home' }">
        <span class="nav__dot" aria-hidden="true"></span>
        Home
      </RouterLink>
      <RouterLink class="nav__link" :to="{ name: 'config' }">
        <span class="nav__dot" aria-hidden="true"></span>
        配置
      </RouterLink>
    </nav>

    <div class="sidebar__footer">
      <div class="sidebar__identity">
        <strong>{{ session?.username ?? 'admin' }}</strong>
        <span>本机管理员</span>
      </div>
      <button type="button" class="btn btn--quiet" :disabled="busy === 'logout'" @click="signOut">
        {{ busy === 'logout' ? '正在退出…' : '退出登录' }}
      </button>
    </div>
  </aside>
</template>
