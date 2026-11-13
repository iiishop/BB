import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  ACTION_LABELS,
  CHECK_LABELS,
  CLASSIFICATION_LABELS,
  STAGE_LABELS,
} from '../src/lib/labels';

interface Schema {
  required?: string[];
  properties?: Record<string, { enum?: string[]; items?: { enum?: string[] } }>;
}

const contract = JSON.parse(
  readFileSync(resolve(process.cwd(), '../server/contract/admin-openapi.json'), 'utf8'),
) as {
  paths: Record<string, Record<string, { 'x-implementation-stage'?: string }>>;
  components: { schemas: Record<string, Schema> };
};

function schema(name: string): Schema {
  const found = contract.components.schemas[name];
  if (!found) throw new Error(`missing contract schema ${name}`);
  return found;
}

function sorted(values: Iterable<string>): string[] {
  return [...values].sort();
}

describe('management wire contract (server/contract/admin-openapi.json)', () => {
  it('keeps the paths and implementation stages the UI consumes', () => {
    const operations = Object.entries(contract.paths).flatMap(([path, methods]) =>
      Object.entries(methods).map(([method, operation]) => ({
        key: `${method.toUpperCase()} ${path}`,
        stage: operation['x-implementation-stage'],
      })),
    );
    const stages = new Map(operations.map((operation) => [operation.key, operation.stage]));

    expect(stages.get('POST /admin/api/login')).toBe('A');
    expect(stages.get('GET /admin/api/session')).toBe('A');
    expect(stages.get('POST /admin/api/password')).toBe('A');
    expect(stages.get('POST /admin/api/logout')).toBe('A');
    expect(stages.get('GET /admin/api/public-config')).toBe('B');
    expect(stages.get('PUT /admin/api/public-config')).toBe('B');
    expect(stages.get('POST /admin/api/probes')).toBe('B');
    expect(stages.get('POST /admin/api/plans')).toBe('B');
    expect(stages.get('POST /admin/api/executions')).toBe('B');
    expect(stages.get('GET /admin/api/tasks/current')).toBe('B');
    expect(stages.get('GET /admin/api/tasks/{task_id}')).toBe('B');
    expect(stages.get('GET /admin/api/tasks/{task_id}/events')).toBe('B');
  });

  it('matches the UI snapshot types field-for-field', () => {
    expect(sorted(Object.keys(schema('AdminSession').properties ?? {}))).toEqual(
      sorted(['username', 'must_change_password', 'csrf_token', 'expires_at']),
    );
    expect(sorted(Object.keys(schema('PublicConfig').properties ?? {}))).toEqual(
      sorted(['version', 'domain', 'active']),
    );
    expect(sorted(Object.keys(schema('ActiveConfig').properties ?? {}))).toEqual(
      sorted(['domain', 'verified_at', 'instance_id', 'tunnel_id']),
    );
    expect(sorted(Object.keys(schema('AdminTask').properties ?? {}))).toEqual(
      sorted([
        'task_id',
        'seq',
        'config_version',
        'kind',
        'stage',
        'classification',
        'issue_code',
        'allowed_actions',
        'requires_confirmation',
        'checks',
        'resources',
        'message',
      ]),
    );
    expect(sorted(Object.keys(schema('CheckResult').properties ?? {}))).toEqual(
      sorted(['check', 'classification', 'issue_code', 'message', 'allowed_actions']),
    );
    expect(sorted(Object.keys(schema('ActionPlan').properties ?? {}))).toEqual(
      sorted([
        'plan_id',
        'config_version',
        'digest',
        'domain',
        'target_service',
        'resources',
        'public_scope',
        'risks',
        'requires_confirmation',
        'expires_at',
      ]),
    );
    expect(sorted(Object.keys(schema('CurrentTask').properties ?? {}))).toEqual(['task']);
  });

  it('keeps classification, stage, action and check vocabularies identical', () => {
    const task = schema('AdminTask').properties ?? {};
    expect(sorted(task.classification?.enum ?? [])).toEqual(sorted(Object.keys(CLASSIFICATION_LABELS)));
    expect(sorted(task.stage?.enum ?? [])).toEqual(sorted(Object.keys(STAGE_LABELS)));
    expect(sorted(task.allowed_actions?.items?.enum ?? [])).toEqual(sorted(Object.keys(ACTION_LABELS)));
    const check = schema('CheckResult').properties ?? {};
    expect(sorted(check.check?.enum ?? [])).toEqual(sorted(Object.keys(CHECK_LABELS)));
  });

  it('requires the session fields the UI relies on after a refresh', () => {
    expect(sorted(schema('AdminSession').required ?? [])).toEqual(
      sorted(['must_change_password', 'csrf_token', 'expires_at']),
    );
    expect(sorted(schema('CurrentTask').required ?? [])).toEqual(['task']);
    expect(sorted(schema('AdminTask').required ?? [])).toEqual(
      sorted(Object.keys(schema('AdminTask').properties ?? {})),
    );
    expect(sorted(schema('ActionPlan').required ?? [])).toEqual(
      sorted([
        'plan_id',
        'config_version',
        'digest',
        'domain',
        'target_service',
        'resources',
        'public_scope',
        'risks',
        'expires_at',
      ]),
    );
  });
});
