<script setup lang="ts">
import { computed } from 'vue';
import type { Action, AdminTask } from '../api/types';
import {
  ACTION_LABELS,
  CLASSIFICATION_LABELS,
  STAGE_LABELS,
  primaryAction,
  requiresPlan,
  taskHeadline,
} from '../lib/labels';
import type { BusyAction } from '../stores/admin-state';

const props = defineProps<{
  task: AdminTask;
  busy: BusyAction;
  planningDisabled?: boolean;
}>();

const emit = defineEmits<{ action: [action: Action] }>();

const action = computed<Action | null>(() => primaryAction(props.task));
const actionLabel = computed(() =>
  action.value ? ACTION_LABELS[action.value] : '查看本机操作指引',
);
const tone = computed(() => {
  if (props.task.classification === 'failed') return 'failed';
  if (props.task.classification === 'unknown') return 'unknown';
  if (props.task.classification === 'passed') return 'passed';
  if (props.task.classification === 'running' || props.task.classification === 'pending') {
    return 'running';
  }
  return 'neutral';
});
const stageLabel = computed(() => STAGE_LABELS[props.task.stage]);
const classificationLabel = computed(() => CLASSIFICATION_LABELS[props.task.classification]);
const isBusy = computed(() => props.busy !== null);
const actionBlocked = computed(
  () => Boolean(props.planningDisabled && action.value && requiresPlan(action.value)),
);
</script>

<template>
  <section class="capsule" aria-labelledby="capsule-headline">
    <div class="capsule__status">
      <span class="capsule__dot" :class="`capsule__dot--${tone}`" aria-hidden="true"></span>
      <div class="capsule__text">
        <div id="capsule-headline" class="capsule__headline">
          <span>{{ taskHeadline(task) }}</span>
          <span class="chip" :class="`chip--${tone}`">{{ classificationLabel }}</span>
          <span class="chip">环节 · {{ stageLabel }}</span>
        </div>
        <p class="capsule__message">{{ task.message || '等待服务端返回下一步状态。' }}</p>
      </div>
    </div>
    <div v-if="action" class="capsule__action">
      <button
        type="button"
        class="btn"
        :disabled="isBusy || actionBlocked"
        :title="actionBlocked ? '请先保存或放弃域名草稿，再生成执行计划' : undefined"
        @click="emit('action', action)"
      >
        {{ actionLabel }}
      </button>
    </div>
    <div v-else-if="task.allowed_actions.length === 0" class="capsule__action">
      <span class="chip">无待执行动作</span>
    </div>
  </section>
</template>
