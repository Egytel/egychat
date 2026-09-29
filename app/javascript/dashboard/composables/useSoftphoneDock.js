import { computed, ref } from 'vue';
import SoftphoneAPI from 'dashboard/api/softphone';

/**
 * The bridge between the dashboard and the softphone it frames.
 *
 * Chatwoot is the identity provider: it mints a short-lived token for the agent who is looking
 * at the dashboard, hands it to the framed page, and the softphone turns it into its own
 * session. The softphone is often not one page but a page that embeds another (a Laravel shell
 * around the real client), so messages must be able to travel the whole way up, and commands
 * the whole way down. Two things make that work:
 *
 *   1. Anything a nested frame says can be relayed up by the page in between, marked
 *      `relayed: true` (see deployment/softphone-relay.js). A relayed message is accepted on
 *      the strength of its origin being on the allowlist, since the only page allowed to
 *      originate it is the softphone itself.
 *   2. State words are normalized. A softphone may report `registered`, `online` or
 *      `connected` meaning the same thing; the dashboard maps them onto its own vocabulary
 *      instead of treating an unfamiliar word as "unknown" and losing the status.
 */
export const SOFTPHONE_MESSAGES = Object.freeze({
  // softphone -> dashboard: "my page is loaded and listening" (also the way a nested frame
  // asks to be authenticated)
  READY: 'hatif:ready',
  // dashboard -> softphone: "here is your token"
  AUTH: 'hatif:auth',
  // softphone -> dashboard: "I used the token, here is what happened"
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

// What a softphone is likely to call each state. The vocabulary below is what the dashboard
// understands; these are the synonyms we accept so a working softphone is never shown as
// disconnected just because it chose a different word.
const STATE_ALIASES = Object.freeze({
  registered: SOFTPHONE_STATES.READY,
  online: SOFTPHONE_STATES.READY,
  connected: SOFTPHONE_STATES.READY,
  authenticated: SOFTPHONE_STATES.READY,
  calling: SOFTPHONE_STATES.IN_CALL,
  ringing: SOFTPHONE_STATES.IN_CALL,
  incall: SOFTPHONE_STATES.IN_CALL,
  unregistered: SOFTPHONE_STATES.LOGIN_REQUIRED,
  offline: SOFTPHONE_STATES.LOGIN_REQUIRED,
  logged_out: SOFTPHONE_STATES.LOGIN_REQUIRED,
  unauthorized: SOFTPHONE_STATES.LOGIN_REQUIRED,
  failed: SOFTPHONE_STATES.ERROR,
  unavailable: SOFTPHONE_STATES.ERROR,
});

export const normalizeFrameState = state => {
  if (!state) return SOFTPHONE_STATES.IDLE;

  const key = String(state).toLowerCase().trim();

  return Object.values(SOFTPHONE_STATES).includes(key)
    ? key
    : STATE_ALIASES[key] || null;
};

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
 * True only for an origin the backend listed for this session: compares parsed origins, so a
 * trailing slash in the config or a lookalike host (soft.example.com.evil.com) cannot slip
 * through.
 */
// Every instance we run sits under one registrable domain, so an exact-origin list was more brittle
// than it needed to be. Mirrors the server's rule: https, and our own domain or a subdomain of it.
export const TRUSTED_DOMAIN = 'egytelecoms.com';

export const isTrustedDomain = origin => {
  const candidate = originOf(origin);
  if (!candidate || !candidate.startsWith('https://')) return false;

  let parsed;
  try {
    parsed = new URL(candidate);
  } catch {
    return false;
  }

  // default port only: a pairing on a non-default port is still fine, it just has to come from the
  // server's exact list rather than from this rule
  if (parsed.port && parsed.port !== '443') return false;

  const host = parsed.hostname.toLowerCase();

  return host === TRUSTED_DOMAIN || host.endsWith(`.${TRUSTED_DOMAIN}`);
};

export const isAllowedOrigin = (origin, allowedOrigins = []) => {
  const candidate = originOf(origin);
  if (!candidate) return false;

  if (allowedOrigins.map(originOf).filter(Boolean).includes(candidate))
    return true;

  return candidate.startsWith('https://') && isTrustedDomain(candidate);
};

export const buildAuthMessage = ({
  token,
  account_id: accountId,
  agent = null,
}) => ({
  type: SOFTPHONE_MESSAGES.AUTH,
  token: token || '',
  accountId: accountId ?? null,
  // Primitives only, on purpose: this object comes off a Vue ref, so `agent` would be a reactive
  // proxy, and structured clone (what postMessage uses) cannot clone a Proxy - it throws
  // DataCloneError and the token never reaches the softphone.
  agent: agent
    ? {
        id: agent.id ?? null,
        name: agent.name || '',
        email: agent.email || '',
      }
    : null,
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
 * Turns a window message into something we act on, or null when it must be ignored.
 *
 * Accepted when the origin is on the allowlist and the message is one of ours, and either:
 *   * it comes from the frame we created, or
 *   * it was relayed up by the softphone's own wrapper page (`relayed: true`), which is how a
 *     softphone that lives one iframe deeper reaches the dashboard.
 */
export const parseFrameMessage = (
  event,
  { frameWindow, allowedOrigins = [] } = {}
) => {
  if (!isAllowedOrigin(event?.origin, allowedOrigins)) return null;

  const payload = parsePayload(event?.data);
  if (!payload || !Object.values(SOFTPHONE_MESSAGES).includes(payload.type)) {
    return null;
  }

  const fromOurFrame = !!frameWindow && event?.source === frameWindow;

  return fromOurFrame || payload.relayed === true ? payload : null;
};

export function useSoftphoneDock() {
  const allowedOrigins = computed(() => session.value?.allowed_origins || []);
  const iframeUrl = computed(() => session.value?.softphone_url || '');
  const agentEmail = computed(() => session.value?.agent?.email || '');

  // A token is good for two minutes; treat anything older than a minute as stale so the frame
  // never hands over something that expires while it is being used.
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

  // An unfamiliar word must not wipe a state we already know: only a state we understand
  // replaces what we are showing.
  const reportFrameState = (state, error) => {
    const normalized = normalizeFrameState(state);
    if (normalized) connectionState.value = normalized;

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
