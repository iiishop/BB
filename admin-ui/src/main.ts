import { createApp } from 'vue';
import App from './App.vue';
import './style.css';
import { createAdminState } from './stores/admin-state';
import { ADMIN_STATE } from './stores/context';
import { createAdminRouter } from './router';

// The session, CSRF token and task state live in memory only. A refresh asks
// GET /admin/api/session; nothing is persisted to localStorage/sessionStorage.
const state = createAdminState();
const router = createAdminRouter(state);

createApp(App).provide(ADMIN_STATE, state).use(router).mount('#app');
