import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { buildPlanExecutionBody, createAdminApi } from '../src/api/client';
import type { AdminTask } from '../src/api/types';
import { makePlan, makeTask } from './helpers/fake-api';

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const FIXED_KEY = '7f1f0d6e-2f3a-4b4c-9d5e-6a7b8c9d0e1f';
const LEGACY_KEY_PREFIX = 'exec:';

function jsonResponse(body: unknown, status = 202): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function pythonInvocation(): { command: string; args: string[] } {
  const configured = process.env.ADMIN_UI_PYTHON;
  if (configured) return { command: configured, args: [] };
  const posix = resolve(process.cwd(), '../server/.venv/bin/python');
  if (existsSync(posix)) return { command: posix, args: [] };
  const windows = resolve(process.cwd(), '../server/.venv/Scripts/python.exe');
  if (existsSync(windows)) return { command: windows, args: [] };
  return {
    command: 'uv',
    args: ['run', '--project', '../server', '--locked', 'python'],
  };
}

function validateWithDto(cases: { name: string; body: unknown }[]) {
  const { command, args } = pythonInvocation();
  const env = { ...process.env };
  if (!env.UV_CACHE_DIR) {
    env.UV_CACHE_DIR = resolve(process.cwd(), '.evidence/uv-cache');
    mkdirSync(env.UV_CACHE_DIR, { recursive: true });
  }
  const output = execFileSync(
    command,
    [...args, resolve(process.cwd(), 'tests/contract/validate_execute_body.py')],
    {
      cwd: process.cwd(),
      env,
      input: JSON.stringify({ cases }),
      encoding: 'utf8',
      timeout: 120_000,
    },
  );
  return JSON.parse(output) as {
    results: { name: string; valid: boolean; errors: { loc: string[]; type: string }[] }[];
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('actual /executions request body against the canonical DTO', () => {
  it('generates a UUID idempotency key and omits an absent management token', async () => {
    const plan = makePlan();
    const task = makeTask({ kind: 'execute', stage: 'queued', classification: 'pending' });
    let captured: unknown;
    vi.stubGlobal(
      'fetch',
      vi.fn(async (_url: string, init: RequestInit) => {
        captured = JSON.parse(String(init.body));
        return jsonResponse(task satisfies AdminTask);
      }),
    );
    const api = createAdminApi(() => 'csrf-value');

    await api.executePlan(plan, FIXED_KEY);

    const body = captured as Record<string, unknown>;
    expect(body.idempotency_key).toBe(FIXED_KEY);
    expect(body.idempotency_key).toMatch(UUID_RE);
    expect(body).not.toHaveProperty('management_token');
    expect(body).toEqual({
      plan_id: plan.plan_id,
      digest: plan.digest,
      expected_version: plan.config_version,
      idempotency_key: FIXED_KEY,
      confirmed: true,
    });
  });

  it('rejects the previous exec:<plan_id> value and accepts the repaired UUID', () => {
    const plan = makePlan();
    const fixed = buildPlanExecutionBody(plan, FIXED_KEY);
    const legacy = buildPlanExecutionBody(plan, `${LEGACY_KEY_PREFIX}${plan.plan_id}`);

    expect(fixed.idempotency_key).toMatch(UUID_RE);
    expect(legacy.idempotency_key).not.toMatch(UUID_RE);

    const { results } = validateWithDto([
      { name: 'repaired-uuid', body: fixed },
      { name: 'legacy-exec-prefix', body: legacy },
    ]);
    const byName = new Map(results.map((result) => [result.name, result]));
    const repaired = byName.get('repaired-uuid');
    const previous = byName.get('legacy-exec-prefix');

    expect(repaired?.valid).toBe(true);
    expect(previous?.valid).toBe(false);
    expect(previous?.errors).toContainEqual({
      loc: ['idempotency_key'],
      type: 'uuid_parsing',
    });
  });
});
