<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import {
  SOFTPHONE_MESSAGES,
  SOFTPHONE_STATES,
  buildAuthMessage,
  normalizeFrameState,
  parseFrameMessage,
  useSoftphoneDock,
} from 'dashboard/composables/useSoftphoneDock';

const props = defineProps({
  url: {
    type: String,
    default: '',
  },
});

const iframeRef = ref(null);
const isFrameReady = ref(false);
// Set once the page inside the frame tells us it is authenticated. The load event arrives
// after the page's own scripts, so without this it would downgrade a working softphone back
// to "connecting" a moment after it authenticated.
const isAcknowledged = ref(false);

const { session, allowedOrigins, loadSession, reportFrameState, clearSession } =
  useSoftphoneDock();

let refreshTimer = null;
let pendingToken = '';
let deliveryTimer = null;

/**
 * The token rides along in the url fragment on the first load.
 *
 * A fragment is never sent to a server, never appears in a referrer and never lands in an
 * access log, and - unlike postMessage - it cannot be lost to a redirect, a slow boot or a
 * login hop: whoever ends up rendering the page has it in `location.hash`. Later tokens (the
 * refresh, which happens on the page we are already talking to) go over postMessage.
 */
const frameSrc = computed(() => {
  const base = props.url || session.value?.softphone_url;
  if (!base) return '';

  const token = pendingToken || session.value.token;
  return token ? `${base}#hatif_token=${encodeURIComponent(token)}` : base;
});

const frameWindow = () => iframeRef.value?.contentWindow;

const postAuth = () => {
  const target = frameWindow();
  if (!target || !session.value?.token) return;
  if (!allowedOrigins.value.length) return;

  const message = buildAuthMessage(session.value);
  allowedOrigins.value.forEach(origin => target.postMessage(message, origin));
};

const clearRefreshTimer = () => {
  if (refreshTimer) clearTimeout(refreshTimer);
  refreshTimer = null;
};

const refreshToken = async () => {
  const data = await loadSession({ force: true });
  if (data) postAuth();
  else reportFrameState(SOFTPHONE_STATES.ERROR);
};

// Chatwoot's token lives two minutes; ask for a fresh one well before the softphone needs it.
const scheduleRefresh = () => {
  const lifetime = (session.value?.expires_in || 120) * 1000;
  clearRefreshTimer();
  refreshTimer = setTimeout(
    () => refreshToken(),
    Math.max(lifetime - 30000, 15000)
  );
};

const sendLogout = () => {
  const target = frameWindow();
  if (!target) return;

  allowedOrigins.value.forEach(origin =>
    target.postMessage({ type: SOFTPHONE_MESSAGES.LOGOUT }, origin)
  );
};

const handleFrameReady = () => {
  isFrameReady.value = true;
  postAuth();
  scheduleRefresh();
};

const handleWindowMessage = event => {
  const message = parseFrameMessage(event, {
    frameWindow: frameWindow(),
    allowedOrigins: allowedOrigins.value,
  });
  if (!message) return;

  switch (message.type) {
    case SOFTPHONE_MESSAGES.READY:
      handleFrameReady();
      break;
    case SOFTPHONE_MESSAGES.AUTH_EXPIRED:
      refreshToken();
      break;
    case SOFTPHONE_MESSAGES.AUTH_RESULT:
      if (message.ok) isAcknowledged.value = true;
      reportFrameState(
        message.ok ? SOFTPHONE_STATES.READY : SOFTPHONE_STATES.LOGIN_REQUIRED
      );
      break;
    case SOFTPHONE_MESSAGES.STATE:
      if (
        [SOFTPHONE_STATES.READY, SOFTPHONE_STATES.IN_CALL].includes(
          normalizeFrameState(message.state)
        )
      ) {
        isAcknowledged.value = true;
      }
      reportFrameState(message.state || SOFTPHONE_STATES.IDLE, message.error);
      break;
    default:
      break;
  }
};

const handleFrameLoad = () => {
  // A page that already told us it is authenticated must not be knocked back to "connecting"
  // by the load event that follows its own scripts.
  if (!isAcknowledged.value) reportFrameState(SOFTPHONE_STATES.LOADING);
  postAuth();
  // The fragment carries the first token, so this only matters when the page inside the frame
  // reloads itself (a softphone that logs itself back in); give it a moment to ask.
  if (deliveryTimer) clearTimeout(deliveryTimer);
  deliveryTimer = setTimeout(() => postAuth(), 2000);
};

onMounted(() => {
  window.addEventListener('message', handleWindowMessage);
  if (iframeRef.value?.contentWindow) handleFrameLoad();
});

onBeforeUnmount(() => {
  window.removeEventListener('message', handleWindowMessage);
  clearRefreshTimer();
  if (deliveryTimer) clearTimeout(deliveryTimer);
});

watch(
  () => session.value?.token,
  (token, previousToken) => {
    if (!token && previousToken) sendLogout();
  }
);

watch(
  () => iframeRef.value,
  () => {
    if (isFrameReady.value) postAuth();
  }
);

defineExpose({ clearSession, postAuth });
</script>

<template>
  <iframe
    ref="iframeRef"
    :src="frameSrc"
    :title="$t('SOFTPHONE_DOCK.TITLE')"
    class="flex-1 w-full border-0 bg-white"
    allow="microphone; autoplay; clipboard-write"
    referrerpolicy="no-referrer"
    @load="handleFrameLoad"
  />
</template>
