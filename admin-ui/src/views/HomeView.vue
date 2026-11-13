<script setup lang="ts">
import { useAdminState } from '../stores/context';

const { session } = useAdminState();
</script>

<template>
  <div class="page">
    <header class="page-header">
      <span class="eyebrow">BB 本机管理</span>
      <h1 class="page-title">欢迎，{{ session?.username ?? 'admin' }}</h1>
      <p class="page-lede">
        这是 BB 的本机管理后台。左侧可在 Home 与配置之间切换；公网域名、探测与 Tunnel 编排都在配置中完成。
      </p>
    </header>

    <section class="hero">
      <h2 class="hero__title">在本机，把 BB 安全地接到公网。</h2>
      <p class="hero__lede">
        公网只公开业务 API；管理页与管理接口始终只保留在本机监听。所有有副作用的操作都需要先探测、再确认这一份具体计划。
      </p>
      <RouterLink class="btn" :to="{ name: 'config' }">前往配置</RouterLink>
      <p class="hero__note">
        <span class="nav__dot" aria-hidden="true"></span>
        本机管理入口 · 不通过 Tunnel 暴露
      </p>
    </section>
  </div>
</template>
