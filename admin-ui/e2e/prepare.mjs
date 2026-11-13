#!/usr/bin/env node
// Remove evidence produced by a previous browser run. Only paths inside
// admin-ui are touched. Keeps the harness deterministic while the webServer
// starts a fresh management database.
import { rmSync } from 'node:fs';
import { resolve } from 'node:path';

const root = process.cwd();
for (const relative of ['.evidence/a', '.evidence/screens', 'test-results']) {
  const target = resolve(root, relative);
  if (!target.startsWith(root)) throw new Error(`refusing to remove ${target}`);
  rmSync(target, { recursive: true, force: true });
}
