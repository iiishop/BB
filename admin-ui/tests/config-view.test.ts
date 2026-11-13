import { flushPromises, mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import ConfigView from '../src/views/ConfigView.vue';
import { createAdminState } from '../src/stores/admin-state';
import { ADMIN_STATE } from '../src/stores/context';
import type { ActionPlan, AdminTask } from '../src/api/types';
import { FakeApi, makePlan, makeTask } from './helpers/fake-api';
import { deferred, setup } from './helpers/state';

describe('ConfigView unsaved domain boundary', () => {
  it('does not create a plan for the saved domain while a new draft is unsaved', async () => {
    const api = new FakeApi();
    const task = makeTask({
      stage: 'finished',
      classification: 'passed',
      allowed_actions: ['create_and_connect'],
    });
    api.probeResult = async () => task;
    api.currentResult = async () => ({ task });
    const state = createAdminState(() => api);
    await state.restoreSession();
    await state.loadConfig();
    await state.startProbe();

    const wrapper = mount(ConfigView, {
      global: {
        provide: { [ADMIN_STATE]: state },
        stubs: { teleport: true, Teleport: true },
      },
    });
    await flushPromises();

    await wrapper.find('input[placeholder="bb.example.com"]').setValue('draft.example.com');
    await flushPromises();

    const planButton = wrapper
      .findAll('button')
      .find((button) => button.text().includes('创建并连接 Tunnel'));
    expect(planButton).toBeTruthy();
    await planButton?.trigger('click');
    await flushPromises();

    expect(api.calls.createPlan).toHaveLength(0);
    expect(wrapper.text()).toContain('域名草稿尚未保存');
    expect(wrapper.text()).toContain('已保存');
    wrapper.unmount();
  });
});


describe('ConfigView specific timing reachability', () => {
  it('keeps the newer probe busy state after a stale plan response returns', async () => {
    const { api, state } = setup();
    const task = makeTask({
      stage: 'finished',
      classification: 'passed',
      allowed_actions: ['create_and_connect'],
    });
    api.probeResult = async () => task;
    api.currentResult = async () => ({ task });
    await state.restoreSession();
    await state.loadConfig();
    await state.startProbe();

    const wrapper = mount(ConfigView, {
      global: {
        provide: { [ADMIN_STATE]: state },
        stubs: { teleport: true, Teleport: true },
      },
    });
    await flushPromises();

    const planGate = deferred<ActionPlan>();
    api.planResult = () => planGate.promise;
    await wrapper.findAll('button').find((button) => button.text().includes('创建并连接 Tunnel'))?.trigger('click');
    await flushPromises();
    expect(state.busy.value).toBe('plan');

    await state.logout();
    await state.login('admin', 'admin');
    await state.loadConfig();
    await flushPromises();
    expect(state.task.value).toBeNull();

    const probeGate = deferred<AdminTask>();
    api.probeResult = () => probeGate.promise;
    await wrapper.findAll('button').find((button) => button.text().includes('开始只读探测'))?.trigger('click');
    await flushPromises();
    expect(state.busy.value).toBe('probe');
    expect(wrapper.text()).toContain('正在启动…');

    planGate.resolve(makePlan());
    await flushPromises();
    expect(state.error.value).toBeNull();
    expect(state.busy.value).toBe('probe');
    expect(wrapper.text()).toContain('正在启动…');
    expect(wrapper.text()).not.toContain('任务已被更新');

    probeGate.resolve(
      makeTask({ task_id: '88888888-8888-4888-8888-888888888888', stage: 'creating_tunnel', classification: 'running', allowed_actions: [] }),
    );
    await flushPromises();
    expect(state.busy.value).toBeNull();
    wrapper.unmount();
  });
});
