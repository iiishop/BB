import { defineConfig, devices } from '@playwright/test';

// Browser evidence runs against the real production build served on the
// management origin. Stage A login/password/session/HTTP boundary are the real
// bb-admin app; the stage B endpoints are either the real 501 handlers or
// explicitly mocked at the browser route layer (see e2e/admin.spec.ts).
const PORT = 9477;

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: 1,
  timeout: 90_000,
  expect: { timeout: 10_000 },
  reporter: [['list'], ['junit', { outputFile: '.evidence/playwright-junit.xml' }]],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    viewport: { width: 1440, height: 900 },
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    reducedMotion: 'reduce',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } },
    },
  ],
  webServer: {
    command: `node e2e/prepare.mjs && uv run --project ../server --locked python e2e/harness.py --port ${PORT} --db .evidence/a/admin.db --dist dist`,
    url: `http://127.0.0.1:${PORT}/admin/`,
    reuseExistingServer: false,
    timeout: 180_000,
  },
});
