import { describe, expect, it } from 'vitest';
import { taskHeadline } from '../src/lib/labels';
import { makeTask } from './helpers/fake-api';

describe('task headline distinguishes completion from public verification', () => {
  it('does not claim public verification for an install-only finished task', () => {
    const headline = taskHeadline(
      makeTask({
        kind: 'execute',
        stage: 'finished',
        classification: 'passed',
        allowed_actions: [],
        checks: [],
        message: 'cloudflared 安装已核实，请重新探测',
      }),
    );

    expect(headline).not.toContain('公网验证通过');
    expect(headline).toBe('任务已完成');
  });

  it('reports installation completion without claiming the instance challenge', () => {
    const headline = taskHeadline(
      makeTask({
        kind: 'execute',
        stage: 'finished',
        classification: 'passed',
        allowed_actions: [],
        checks: [
          {
            check: 'installation',
            classification: 'passed',
            issue_code: null,
            message: 'cloudflared 已安装',
            allowed_actions: [],
          },
        ],
      }),
    );

    expect(headline).toBe('安装完成');
    expect(headline).not.toContain('公网验证通过');
  });

  it('only claims public verification when the instance check actually passed', () => {
    const verified = taskHeadline(
      makeTask({
        kind: 'execute',
        stage: 'finished',
        classification: 'passed',
        allowed_actions: [],
        checks: [
          {
            check: 'instance',
            classification: 'passed',
            issue_code: null,
            message: '随机挑战匹配当前实例',
            allowed_actions: [],
          },
        ],
      }),
    );
    const unverified = taskHeadline(
      makeTask({
        kind: 'execute',
        stage: 'finished',
        classification: 'passed',
        allowed_actions: [],
        checks: [
          {
            check: 'instance',
            classification: 'unknown',
            issue_code: 'instance_not_verified',
            message: '当前实例尚未验证',
            allowed_actions: [],
          },
        ],
      }),
    );

    expect(verified).toBe('公网验证通过');
    expect(unverified).not.toBe('公网验证通过');
  });
});
