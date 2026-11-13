import { flushPromises, mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import ConfigView from '../src/views/ConfigView.vue';
import { createAdminState } from '../src/stores/admin-state';
import { ADMIN_STATE } from '../src/stores/context';
import { FakeApi, makeTask } from './helpers/fake-api';

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
