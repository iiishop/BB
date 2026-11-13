import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import ConfirmPlanDialog from '../src/components/ConfirmPlanDialog.vue';
import StatusCapsule from '../src/components/StatusCapsule.vue';
import TokenPromptDialog from '../src/components/TokenPromptDialog.vue';
import { makePlan, makeTask } from './helpers/fake-api';

const global = { stubs: { teleport: true, Teleport: true } };

function buttonByText(wrapper: ReturnType<typeof mount>, text: string) {
  return wrapper.findAll('button').find((button) => button.text().includes(text));
}

describe('StatusCapsule', () => {
  it('renders one capsule and exposes only the server-selected action', async () => {
    const wrapper = mount(StatusCapsule, {
      props: {
        task: makeTask({
          allowed_actions: ['authorize', 'verify'],
          stage: 'awaiting_authorization',
        }),
        busy: null,
      },
    });

    expect(wrapper.find('.capsule').exists()).toBe(true);
    expect(wrapper.text()).toContain('等待管理凭据');
    expect(wrapper.text()).toContain('未知 / 未授权');
    const button = buttonByText(wrapper, '补充管理凭据');
    expect(button).toBeTruthy();
    expect(wrapper.text()).not.toContain('验证公网实例');

    await button?.trigger('click');
    expect(wrapper.emitted('action')).toEqual([['authorize']]);
  });

  it('shows no action button when the server allows none', () => {
    const wrapper = mount(StatusCapsule, {
      props: {
        task: makeTask({
          stage: 'finished',
          classification: 'passed',
          allowed_actions: [],
          message: '实例挑战匹配',
        }),
        busy: null,
      },
    });

    expect(wrapper.text()).toContain('公网验证通过');
    expect(wrapper.findAll('button')).toHaveLength(0);
  });
});

describe('ConfirmPlanDialog', () => {
  it('lists domain, target, resources, scope and risks, and requires explicit acknowledgement', async () => {
    const plan = makePlan();
    const wrapper = mount(ConfirmPlanDialog, {
      props: { plan, busy: null },
      global,
      attachTo: document.body,
    });

    expect(wrapper.text()).toContain('bb.example.com');
    expect(wrapper.text()).toContain('127.0.0.1:8000');
    expect(wrapper.text()).toContain('bb-admin');
    expect(wrapper.text()).toContain('业务 API');
    expect(wrapper.text()).toContain('将创建 Cloudflare 资源');

    const confirm = buttonByText(wrapper, '确认并执行') as unknown as { element: HTMLButtonElement };
    expect(confirm.element.disabled).toBe(true);
    await wrapper.find('input[type="checkbox"]').setValue(true);
    await wrapper.vm.$nextTick();
    const enabled = buttonByText(wrapper, '确认并执行') as unknown as { element: HTMLButtonElement };
    expect(enabled.element.disabled).toBe(false);

    wrapper.unmount();
  });

  it('emits cancel for the cancel button, Escape and backdrop, without a confirm', async () => {
    const wrapper = mount(ConfirmPlanDialog, {
      props: { plan: makePlan(), busy: null },
      global,
      attachTo: document.body,
    });

    const cancel = buttonByText(wrapper, '取消');
    await cancel?.trigger('click');
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    await wrapper.find('.overlay').trigger('click');

    expect(wrapper.emitted('cancel')).toHaveLength(3);
    expect(wrapper.emitted('confirm')).toBeUndefined();
    wrapper.unmount();
  });

  it('emits the exact confirmation with an optional write-only token and clears it', async () => {
    const wrapper = mount(ConfirmPlanDialog, {
      props: { plan: makePlan(), busy: null },
      global,
      attachTo: document.body,
    });

    await wrapper.find('input[type="checkbox"]').setValue(true);
    await wrapper.find('input[type="password"]').setValue('management-secret');
    await buttonByText(wrapper, '确认并执行')?.trigger('click');

    expect(wrapper.emitted('confirm')).toEqual([['management-secret']]);
    expect((wrapper.find('input[type="password"]').element as HTMLInputElement).value).toBe('');
    wrapper.unmount();
  });
});

describe('TokenPromptDialog', () => {
  it('accepts a write-only management token and never shows it again', async () => {
    const wrapper = mount(TokenPromptDialog, {
      props: { busy: null, message: '需要管理权限' },
      global,
      attachTo: document.body,
    });

    const submit = buttonByText(wrapper, '提交凭据并恢复任务') as unknown as {
      element: HTMLButtonElement;
      trigger: (event: string) => Promise<void>;
    };
    expect(submit.element.disabled).toBe(true);
    await wrapper.find('input[type="password"]').setValue('token-value');
    await wrapper.vm.$nextTick();
    const enabled = buttonByText(wrapper, '提交凭据并恢复任务') as unknown as {
      element: HTMLButtonElement;
      trigger: (event: string) => Promise<void>;
    };
    expect(enabled.element.disabled).toBe(false);
    await enabled.trigger('click');

    expect(wrapper.emitted('submit')).toEqual([['token-value']]);
    expect((wrapper.find('input[type="password"]').element as HTMLInputElement).value).toBe('');
    wrapper.unmount();
  });
});
