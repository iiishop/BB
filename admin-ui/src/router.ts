import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router';
import HomeView from './views/HomeView.vue';
import ConfigView from './views/ConfigView.vue';
import LoginView from './views/LoginView.vue';
import ChangePasswordView from './views/ChangePasswordView.vue';
import type { AdminState } from './stores/admin-state';

const routes: RouteRecordRaw[] = [
  { path: '/', redirect: '/home' },
  { path: '/home', name: 'home', component: HomeView },
  { path: '/config', name: 'config', component: ConfigView },
  { path: '/login', name: 'login', component: LoginView },
  { path: '/change-password', name: 'change-password', component: ChangePasswordView },
  { path: '/:pathMatch(.*)*', redirect: '/home' },
];

export function createAdminRouter(state: AdminState) {
  const router = createRouter({
    history: createWebHistory('/admin/'),
    routes,
    scrollBehavior: () => ({ top: 0 }),
  });

  router.beforeEach(async (to) => {
    if (!state.authenticated.value) {
      await state.restoreSession();
    }
    if (!state.authenticated.value) {
      return to.name === 'login' ? true : { name: 'login' };
    }
    if (state.mustChangePassword.value) {
      return to.name === 'change-password' ? true : { name: 'change-password' };
    }
    if (to.name === 'login' || to.name === 'change-password') {
      return { name: 'home' };
    }
    return true;
  });

  state.setUnauthorizedHandler(() => {
    void router.push({ name: 'login', query: { expired: '1' } });
  });

  return router;
}
