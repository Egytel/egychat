<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import {
  SOFTPHONE_ERRORS,
  SOFTPHONE_STATES,
  useSoftphoneDock,
} from 'dashboard/composables/useSoftphoneDock';
import SoftphoneFrame from './SoftphoneFrame.vue';

const DEFAULT_WIDTH = 380;
const DEFAULT_HEIGHT = 640;
const MIN_WIDTH = 320;
const MIN_HEIGHT = 420;
const EDGE_MARGIN = 32;

const { t } = useI18n();
const currentUser = useMapGetter('getCurrentUser');
const { uiSettings, updateUISettings } = useUISettings();

const {
  connectionState,
  errorCode,
  iframeUrl,
  agentEmail,
  isLoading,
  loadSession,
} = useSoftphoneDock();

const isOpen = ref(false);
const hasLoadedFrame = ref(false);
const frameKey = ref(0);
const panelSize = ref({ width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT });

const isMarkedAgent = computed(
  () => currentUser.value?.softphone_enabled === true
);
const savedSettings = computed(() => uiSettings.value?.softphone || {});

const stateLabel = computed(() => {
  const key = Object.values(SOFTPHONE_STATES).includes(connectionState.value)
    ? connectionState.value
    : SOFTPHONE_STATES.IDLE;

  return t(`SOFTPHONE_DOCK.STATE.${key}`);
});

const stateColor = computed(() => {
  switch (connectionState.value) {
    case SOFTPHONE_STATES.READY:
      return 'bg-n-teal-9';
    case SOFTPHONE_STATES.IN_CALL:
      return 'bg-n-teal-9 animate-pulse';
    case SOFTPHONE_STATES.LOGIN_REQUIRED:
      return 'bg-n-amber-9';
    case SOFTPHONE_STATES.LOADING:
      return 'bg-n-slate-9 animate-pulse';
    case SOFTPHONE_STATES.ERROR:
      return 'bg-n-ruby-9';
    default:
      return 'bg-n-slate-7';
  }
});

const errorKey = computed(() => {
  const known = [
    SOFTPHONE_ERRORS.DISABLED,
    SOFTPHONE_ERRORS.NOT_CONFIGURED,
    SOFTPHONE_ERRORS.RATE_LIMITED,
  ];

  return known.includes(errorCode.value)
    ? errorCode.value
    : SOFTPHONE_ERRORS.NETWORK;
});

const hasError = computed(() => !!errorCode.value);

const persistSettings = () => {
  updateUISettings({
    softphone: {
      open: isOpen.value,
      width: panelSize.value.width,
      height: panelSize.value.height,
    },
  });
};

const openDock = async () => {
  isOpen.value = true;
  persistSettings();

  const session = await loadSession();
  hasLoadedFrame.value = !!session?.softphone_url;
};

const toggle = () => {
  if (isOpen.value) {
    isOpen.value = false;
    persistSettings();
    return;
  }

  openDock();
};

const reload = async () => {
  const session = await loadSession({ force: true });
  hasLoadedFrame.value = !!session?.softphone_url;
  if (hasLoadedFrame.value) frameKey.value += 1;
};

const popOut = () => {
  if (iframeUrl.value)
    window.open(iframeUrl.value, '_blank', 'noopener,noreferrer');
};

// Resizing drags the top-left corner: the panel is anchored to the bottom-right so a call in
// progress never jumps around while the agent changes its size.
let resizeStart = null;

const clamp = (value, min, max) => Math.min(Math.max(value, min), max);

const onResizeMove = event => {
  if (!resizeStart) return;

  panelSize.value = {
    width: clamp(
      resizeStart.width - (event.clientX - resizeStart.x),
      MIN_WIDTH,
      window.innerWidth - EDGE_MARGIN
    ),
    height: clamp(
      resizeStart.height - (event.clientY - resizeStart.y),
      MIN_HEIGHT,
      window.innerHeight - EDGE_MARGIN * 3
    ),
  };
};

const stopResize = () => {
  if (!resizeStart) return;

  resizeStart = null;
  window.removeEventListener('pointermove', onResizeMove);
  window.removeEventListener('pointerup', stopResize);
  persistSettings();
};

const startResize = event => {
  resizeStart = { x: event.clientX, y: event.clientY, ...panelSize.value };
  window.addEventListener('pointermove', onResizeMove);
  window.addEventListener('pointerup', stopResize);
};

const applySavedSettings = () => {
  const { width, height } = savedSettings.value;
  if (width) panelSize.value.width = clamp(width, MIN_WIDTH, window.innerWidth);
  if (height)
    panelSize.value.height = clamp(height, MIN_HEIGHT, window.innerHeight);
};

onMounted(() => {
  applySavedSettings();
  // Stay collapsed until the agent asks for the softphone: no iframe, no mic prompt on load.
  isOpen.value = false;
});

onBeforeUnmount(() => {
  stopResize();
});

watch(savedSettings, applySavedSettings);
</script>

<template>
  <div class="softphone-dock">
    <template v-if="isMarkedAgent">
      <button
        v-show="!isOpen"
        type="button"
        class="fixed top-1/3 z-40 flex items-center gap-2 px-2 py-3 border shadow-lg rounded-lg ltr:right-0 rtl:left-0 ltr:rounded-r-none rtl:rounded-l-none border-n-weak bg-n-background hover:bg-n-alpha-2"
        :title="$t('SOFTPHONE_DOCK.TOGGLE.OPEN')"
        @click="toggle"
      >
        <span class="i-lucide-phone size-4 text-n-slate-12" />
        <span class="size-2 rounded-full" :class="stateColor" />
      </button>

      <section
        v-show="isOpen"
        class="fixed bottom-0 z-40 flex flex-col max-w-[100vw] max-h-[calc(100dvh-1rem)] overflow-hidden border shadow-2xl ltr:right-0 rtl:left-0 sm:bottom-20 sm:ltr:right-4 sm:rtl:left-4 sm:max-h-[calc(100dvh-6rem)] sm:rounded-xl border-n-weak bg-n-background"
        :style="{
          width: `${panelSize.width}px`,
          height: `${panelSize.height}px`,
        }"
      >
        <header
          class="flex items-center justify-between gap-2 px-3 border-b shrink-0 h-11 border-n-weak"
        >
          <div class="flex items-center min-w-0 gap-2">
            <span class="i-lucide-phone size-4 shrink-0 text-n-slate-11" />
            <span class="text-sm font-medium truncate text-n-slate-12">
              {{ $t('SOFTPHONE_DOCK.TITLE') }}
            </span>
            <span class="hidden truncate sm:inline text-xs text-n-slate-10">
              {{ agentEmail }}
            </span>
          </div>

          <div class="flex items-center gap-1 shrink-0">
            <span class="flex items-center gap-1 mr-1">
              <span class="size-2 rounded-full" :class="stateColor" />
              <span class="hidden text-xs sm:inline text-n-slate-10">
                {{ stateLabel }}
              </span>
            </span>

            <button
              type="button"
              class="p-1 rounded hover:bg-n-alpha-2"
              :title="$t('SOFTPHONE_DOCK.ACTIONS.RELOAD')"
              @click="reload"
            >
              <span class="i-lucide-refresh-cw size-4 text-n-slate-11" />
            </button>
            <button
              type="button"
              class="p-1 rounded hover:bg-n-alpha-2"
              :title="$t('SOFTPHONE_DOCK.ACTIONS.POP_OUT')"
              @click="popOut"
            >
              <span class="i-lucide-external-link size-4 text-n-slate-11" />
            </button>
            <button
              type="button"
              class="p-1 rounded hover:bg-n-alpha-2"
              :title="$t('SOFTPHONE_DOCK.TOGGLE.CLOSE')"
              @click="toggle"
            >
              <span class="i-lucide-chevron-right size-4 text-n-slate-11" />
            </button>
          </div>
        </header>

        <div
          v-if="hasError"
          class="flex flex-col items-center justify-center flex-1 gap-3 p-6 text-center"
        >
          <span class="i-lucide-phone-off size-6 text-n-slate-10" />
          <p class="text-sm text-n-slate-11">
            {{ $t(`SOFTPHONE_DOCK.ERRORS.${errorKey}`) }}
          </p>
          <button
            v-if="errorKey !== 'softphone_disabled'"
            type="button"
            class="px-3 py-1 text-sm rounded bg-n-alpha-2 hover:bg-n-alpha-3"
            @click="reload"
          >
            {{ $t('SOFTPHONE_DOCK.ACTIONS.RETRY') }}
          </button>
        </div>

        <div
          v-else-if="isLoading && !hasLoadedFrame"
          class="flex items-center justify-center flex-1 gap-2"
        >
          <span
            class="i-lucide-loader-circle size-5 animate-spin text-n-slate-10"
          />
          <span class="text-sm text-n-slate-11">
            {{ $t('SOFTPHONE_DOCK.STATE.LOADING') }}
          </span>
        </div>

        <SoftphoneFrame
          v-else-if="hasLoadedFrame"
          :key="frameKey"
          :url="iframeUrl"
          class="flex-1 min-h-0"
        />

        <button
          type="button"
          class="absolute z-10 hidden size-4 cursor-nw-resize sm:block ltr:left-0 rtl:right-0 top-0"
          :title="$t('SOFTPHONE_DOCK.ACTIONS.RESIZE')"
          @pointerdown.prevent="startResize"
        >
          <span class="i-lucide-grip-horizontal size-4 text-n-slate-8" />
        </button>
      </section>
    </template>
  </div>
</template>
