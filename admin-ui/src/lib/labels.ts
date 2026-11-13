import type {
  Action,
  AdminTask,
  Classification,
  TaskStage,
} from '../api/types';

export const ACTION_LABELS: Record<Action, string> = {
  install: '安装 cloudflared',
  authorize: '补充管理凭据',
  create_and_connect: '创建并连接 Tunnel',
  verify: '验证公网实例',
  reconcile: '核对实际资源',
  local_admin: '需要本机管理员操作',
};

export const STAGE_LABELS: Record<TaskStage, string> = {
  queued: '已排队',
  detecting: '检测中',
  awaiting_authorization: '等待管理凭据',
  awaiting_local_admin: '等待本机管理员操作',
  installing: '安装中',
  creating_tunnel: '创建 Tunnel',
  creating_route: '创建 DNS 路由',
  connecting: '连接中',
  verifying: '验证公网实例',
  reconciling: '核对实际资源',
  finished: '已完成',
};

export const CLASSIFICATION_LABELS: Record<Classification, string> = {
  pending: '等待执行',
  running: '进行中',
  passed: '通过',
  failed: '失败',
  unknown: '未知 / 未授权',
  not_applicable: '不适用',
};

export const CHECK_LABELS = {
  installation: '安装',
  service: '系统服务',
  connection: 'Tunnel 连接',
  authorization: '管理权限',
  route: 'DNS 路由',
  instance: '实例验证',
} as const;

export function primaryAction(task: AdminTask): Action | null {
  // The capsule exposes the server-selected action, never a client inference.
  return task.allowed_actions[0] ?? null;
}

export function taskHeadline(task: AdminTask): string {
  if (task.stage !== 'finished') return STAGE_LABELS[task.stage];
  return task.classification === 'passed' ? '公网验证通过' : '任务已结束';
}
