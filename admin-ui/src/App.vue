<script setup lang="ts">
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import AppSidebar from './components/AppSidebar.vue';
import { useAdminState } from './stores/context';

const { authenticated, restoring } = useAdminState();
const route = useRoute();

// Forced password change is a closed gate: no sidebar or other navigation.
const bare = computed(() => !authenticated.value || route.name === 'change-password');
</script>

<template>
  <div v-if="restoring" class="auth-frame" role="status" aria-live="polite">
    <div class="auth-card">
      <div class="auth-card__brand">
        <span class="brand__mark" aria-hidden="true">BB</span>
        <span class="brand__name">管理入口</span>
      </div>
      <p class="auth-lede">正在恢复本机管理会话…</p>
    </div>
  </div>
  <div v-else-if="bare" class="auth-frame">
    <RouterView />
  </div>
  <div v-else class="shell">
    <AppSidebar />
    <main class="main">
      <RouterView />
    </main>
  </div>
</template>
