import { defineConfig } from 'vitest/config';
import base from './vitest.config';

// Replace (not merge/concatenate) include: review runs only these probes.
export default defineConfig({
  ...base,
  test: { ...base.test, include: ['review-probes/**/*.test.ts'] },
});
