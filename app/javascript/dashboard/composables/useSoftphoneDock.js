import { computed, ref } from 'vue';
import SoftphoneAPI from 'dashboard/api/softphone';

/**
 * The bridge between the dashboard and the softphone it frames.
 *
 * Chatwoot is the identity provider: it mints a short-lived token for the agent who is
 * looking at the dashboard, hands it to the framed page, and the softphone turns it into its
 * own session. Everything the two sides say to each other goes through the message types
 * below, and every inbound message is checked twice: the sender must be the frame we created,
 * and its origin must be on the allowlist the backend returned.
 */
export const SOFTPHONE_MESSAGES = Object.freeze({
  // softphone -> dashboard: "my page is loaded and listening"
  READY: 'hatif:ready',
  // dashboard -> softphone: "here is your token"
  AUTH: 'hatif:auth',
  // softphone -> dashboard: "I used it, here is what happened"
  AUTH_RESULT: 'hatif:auth-result',
  // softphone -> dashboard: "this is what I am doing now"
  STATE: 'hatif:state',
  // softphone -> dashboard: "the token I hold is stale"
  AUTH_EXPIRED: 'hatif:auth-expired',
  // dashboard -> softphone: "the agent signed out"
  LOGOUT: 'hatif:logout',
});

export const SOFTPHONE_STATES = Object.freeze({
  IDLE: 'idle',
  LOADING: 'loading',
  READY: 'ready',
  LOGIN_REQUIRED: 'login_required',
  IN_CALL: 'in_call',
  ERROR: 'error',
});

export const SOFTPHONE_ERRORS = Object.freeze({
  DISABLED: 'softphone_disabled',
  NOT_CONFIGURED: 'softphone_not_configured',
  RATE_LIMITED: 'rate_limited',
  NETWORK: 'network',
});

// The dock lives once in the dashboard layout, but both the dock and the frame read the same
// session and connection state, so this state is module level on purpose.
const session = ref(null);
const sessionFetchedAt = ref(0);
const connectionState = ref(SOFTPHONE_STATES.IDLE);
const isLoading = ref(false);
const errorCode = ref('');

const originOf = value => {
  try {
    return new URL(value).origin;
  } catch {
    return '';
  }
};

/**
 * True only for an origin that the backend listed for this session: compares parsed origins,
 * so a trailing slash in the config or a lookalike host (`soft.example.com.evil.com`) cannot
 * slip through.
 */
export const isAllowedOrigin = (origin, allowedOrigins = []) => {
  const candidate = originOf(origin);
  if (!candidate) return false;

  return allowedOrigins.map(originOf).filter(Boolean).includes(candidate);
};

export const buildAuthMessage = ({ token, account_id: accountId, agent }) => ({
  type: SOFTPHONE_MESSAGES.AUTH,
  token,
  accountId,
  agent,
});

const parsePayload = data => {
  if (typeof data !== 'string') return data;

  try {
    return JSON.parse(data);
  } catch {
    return null;
  }
};

/**
 * Turns a window message into something we act on, or null when it must be ignored: not our
 * frame, not an allowed origin, not one of our message types.
 */
export const parseFrameMessage = (
  event,
  { frameWindow, allowedOrigins = [] } = {}
) => {
  if (!frameWindow || event?.source !== frameWindow) return null;
  if (!isAllowedOrigin(event?.origin, allowedOrigins)) return null;

  const payload = parsePayload(event?.data);
  if (!payload || !Object.values(SOFTPHONE_MESSAGES).includes(payload.type)) {
    return null;
  }

  return payload;
};

export function useSoftphoneDock() {
  const allowedOrigins = computed(() => session.value?.allowed_origins || []);
  const iframeUrl = computed(() => session.value?.softphone_url || '');
  const agentEmail = computed(() => session.value?.agent?.email || '');

  // A token is good for two minutes; treat anything older than a minute as stale so the frame
  // never receives something that expires while it is being used.
  const isSessionFresh = computed(
    () => !!session.value && Date.now() - sessionFetchedAt.value < 60000
  );

  const clearSession = () => {
    session.value = null;
    sessionFetchedAt.value = 0;
    connectionState.value = SOFTPHONE_STATES.IDLE;
    errorCode.value = '';
  };

  const loadSession = async ({ force = false } = {}) => {
    if (!force && isSessionFresh.value) return session.value;
    if (isLoading.value) return session.value;

    isLoading.value = true;
    errorCode.value = '';

    try {
      const data = await SoftphoneAPI.getSession();
      session.value = data;
      sessionFetchedAt.value = Date.now();

      return data;
    } catch (error) {
      session.value = null;
      errorCode.value =
        error?.response?.data?.error || SOFTPHONE_ERRORS.NETWORK;

      return null;
    } finally {
      isLoading.value = false;
    }
  };

  const reportFrameState = (state, error) => {
    connectionState.value = state;

    if (error) errorCode.value = error;
  };

  return {
    session,
    sessionFetchedAt,
    connectionState,
    isLoading,
    errorCode,
    allowedOrigins,
    iframeUrl,
    agentEmail,
    isSessionFresh,
    loadSession,
    clearSession,
    reportFrameState,
  };
}
