import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

// The build is served by bb-admin under /admin/ on the same origin as
// /admin/api. Keep the base relative to that mount; never introduce an API
// origin override or CORS.
export default defineConfig({
  base: '/admin/',
  plugins: [vue()],
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    emptyOutDir: true,
    sourcemap: false,
    target: 'es2022',
  },
});
