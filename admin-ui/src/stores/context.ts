import type { InjectionKey } from 'vue';
import { inject } from 'vue';
import type { AdminState } from './admin-state';

export const ADMIN_STATE: InjectionKey<AdminState> = Symbol('bb-admin-state');

export function useAdminState(): AdminState {
  const state = inject(ADMIN_STATE);
  if (!state) throw new Error('admin state is not provided');
  return state;
}
