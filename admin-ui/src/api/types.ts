// Wire types mirrored from server/contract/admin-openapi.json (contract 1.0.0).
// tests/wire-contract.test.ts fails if these drift from the machine contract.
// Do not add frontend-only semantics here; server DTOs are authoritative.

export type Action =
  | 'install'
  | 'authorize'
  | 'create_and_connect'
  | 'verify'
  | 'reconcile'
  | 'local_admin';

export type Classification =
  | 'pending'
  | 'running'
  | 'passed'
  | 'failed'
  | 'unknown'
  | 'not_applicable';

export type CheckKind =
  | 'installation'
  | 'service'
  | 'connection'
  | 'authorization'
  | 'route'
  | 'instance';

export type TaskKind = 'probe' | 'execute';

export type TaskStage =
  | 'queued'
  | 'detecting'
  | 'awaiting_authorization'
  | 'awaiting_local_admin'
  | 'installing'
  | 'creating_tunnel'
  | 'creating_route'
  | 'connecting'
  | 'verifying'
  | 'reconciling'
  | 'finished';

export type ResourceKind = 'package' | 'service' | 'tunnel' | 'dns';

export interface AdminSession {
  username: 'admin';
  must_change_password: boolean;
  csrf_token: string;
  expires_at: number;
}

export interface ActiveConfig {
  domain: string;
  verified_at: number;
  instance_id: string;
  tunnel_id: string;
}

export interface PublicConfig {
  version: number;
  domain: string | null;
  active: ActiveConfig | null;
}

export interface CheckResult {
  check: CheckKind;
  classification: Classification;
  issue_code: string | null;
  message: string;
  allowed_actions: Action[];
}

export interface OwnedResource {
  kind: ResourceKind;
  resource_id: string;
  ownership: 'created_by_task' | 'reused' | 'unknown';
}

export interface AdminTask {
  task_id: string;
  seq: number;
  config_version: number;
  kind: TaskKind;
  stage: TaskStage;
  classification: Classification;
  issue_code: string | null;
  allowed_actions: Action[];
  requires_confirmation: boolean;
  checks: CheckResult[];
  resources: OwnedResource[];
  message: string;
}

export interface CurrentTask {
  task: AdminTask | null;
}

export interface ResourceIntent {
  kind: ResourceKind;
  operation: 'create' | 'reuse';
  name: string;
}

export interface ActionPlan {
  plan_id: string;
  config_version: number;
  digest: string;
  domain: string;
  target_service: string;
  resources: ResourceIntent[];
  public_scope: string[];
  risks: string[];
  requires_confirmation: true;
  expires_at: number;
}

export interface ErrorField {
  field?: string;
  code?: string;
  message?: string;
}

export interface ApiErrorBody {
  error: {
    code: string;
    message: string;
    fields: ErrorField[];
  };
}

/** Request body for the stage B authorization-resume seam (B/C addendum). */
export interface TaskAuthorizationRequest {
  management_token: string;
}

export function isTerminalTask(task: AdminTask): boolean {
  return task.stage === 'finished';
}

export function isNonTerminalTask(task: AdminTask): boolean {
  return task.stage !== 'finished';
}
