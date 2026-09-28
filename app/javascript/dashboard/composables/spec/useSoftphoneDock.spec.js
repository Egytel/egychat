import SoftphoneAPI from 'dashboard/api/softphone';
import {
  SOFTPHONE_ERRORS,
  SOFTPHONE_MESSAGES,
  SOFTPHONE_STATES,
  buildAuthMessage,
  isAllowedOrigin,
  normalizeFrameState,
  parseFrameMessage,
  useSoftphoneDock,
} from '../useSoftphoneDock';

vi.mock('dashboard/api/softphone');

const ALLOWED_ORIGINS = ['https://soft.egytelecoms.com'];
const SESSION = {
  softphone_url: 'https://soft.egytelecoms.com',
  allowed_origins: ALLOWED_ORIGINS,
  token: 'a.jwt.token',
  expires_in: 120,
  account_id: 2,
  agent: { id: 3, email: 'c2agent1@egytelecoms.com' },
};

describe('isAllowedOrigin', () => {
  it('accepts the origin the backend listed', () => {
    expect(
      isAllowedOrigin('https://soft.egytelecoms.com', ALLOWED_ORIGINS)
    ).toBe(true);
  });

  it('accepts a configured origin written with a trailing slash', () => {
    expect(
      isAllowedOrigin('https://soft.egytelecoms.com', [
        'https://soft.egytelecoms.com/',
      ])
    ).toBe(true);
  });

  it('rejects a lookalike host that merely starts with the allowed one', () => {
    expect(
      isAllowedOrigin('https://soft.egytelecoms.com.evil.test', ALLOWED_ORIGINS)
    ).toBe(false);
  });

  it('rejects another scheme or port', () => {
    expect(
      isAllowedOrigin('http://soft.egytelecoms.com', ALLOWED_ORIGINS)
    ).toBe(false);
    expect(
      isAllowedOrigin('https://soft.egytelecoms.com:8443', ALLOWED_ORIGINS)
    ).toBe(false);
  });

  it('rejects junk instead of throwing', () => {
    expect(isAllowedOrigin('not-a-url', ALLOWED_ORIGINS)).toBe(false);
    expect(isAllowedOrigin('', ALLOWED_ORIGINS)).toBe(false);
    expect(isAllowedOrigin(undefined, ALLOWED_ORIGINS)).toBe(false);
  });
});

describe('parseFrameMessage', () => {
  const frameWindow = { name: 'our-frame' };
  const allowedOrigins = ALLOWED_ORIGINS;
  const messageFrom = (overrides = {}) => ({
    source: frameWindow,
    origin: 'https://soft.egytelecoms.com',
    data: { type: SOFTPHONE_MESSAGES.READY },
    ...overrides,
  });
  const options = { frameWindow, allowedOrigins };

  it('accepts a known message sent by our frame from an allowed origin', () => {
    expect(parseFrameMessage(messageFrom(), options)).toEqual({
      type: SOFTPHONE_MESSAGES.READY,
    });
  });

  it('accepts a JSON string payload', () => {
    const event = messageFrom({
      data: JSON.stringify({
        type: SOFTPHONE_MESSAGES.STATE,
        state: 'in_call',
      }),
    });

    expect(parseFrameMessage(event, options)).toEqual({
      type: SOFTPHONE_MESSAGES.STATE,
      state: 'in_call',
    });
  });

  it('ignores a message that came from another window', () => {
    expect(
      parseFrameMessage(messageFrom({ source: { name: 'another' } }), options)
    ).toBeNull();
  });

  it('ignores everything when we do not hold the frame window yet', () => {
    expect(
      parseFrameMessage(messageFrom(), { frameWindow: null, allowedOrigins })
    ).toBeNull();
  });

  it('ignores a message from an origin the backend did not allow', () => {
    expect(
      parseFrameMessage(
        messageFrom({ origin: 'https://somewhere.else.test' }),
        options
      )
    ).toBeNull();
  });

  it('ignores a message type we do not handle', () => {
    expect(
      parseFrameMessage(
        messageFrom({ data: { type: 'hatif:surprise' } }),
        options
      )
    ).toBeNull();
  });

  it('ignores a payload that is not JSON', () => {
    expect(
      parseFrameMessage(messageFrom({ data: 'hello there' }), options)
    ).toBeNull();
    expect(parseFrameMessage(messageFrom({ data: null }), options)).toBeNull();
  });
});

describe('buildAuthMessage', () => {
  it('carries the token and the agent, and nothing about the endpoint', () => {
    expect(
      buildAuthMessage({ ...SESSION, token: 'jwt', secret: 'never-send-me' })
    ).toEqual({
      type: SOFTPHONE_MESSAGES.AUTH,
      token: 'jwt',
      accountId: 2,
      agent: { id: 3, email: 'c2agent1@egytelecoms.com' },
    });
  });
});

describe('useSoftphoneDock', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useSoftphoneDock().clearSession();
  });

  it('keeps the session the backend handed over', async () => {
    SoftphoneAPI.getSession.mockResolvedValue(SESSION);

    const { loadSession, session, errorCode, allowedOrigins, iframeUrl } =
      useSoftphoneDock();
    await loadSession();

    expect(session.value.token).toBe('a.jwt.token');
    expect(iframeUrl.value).toBe('https://soft.egytelecoms.com');
    expect(allowedOrigins.value).toEqual(ALLOWED_ORIGINS);
    expect(errorCode.value).toBe('');
  });

  it('reports the reason the backend refused instead of a generic failure', async () => {
    SoftphoneAPI.getSession.mockRejectedValue({
      response: { data: { error: SOFTPHONE_ERRORS.DISABLED } },
    });

    const { loadSession, errorCode, session } = useSoftphoneDock();
    await loadSession();

    expect(errorCode.value).toBe(SOFTPHONE_ERRORS.DISABLED);
    expect(session.value).toBeNull();
  });

  it('falls back to a network error when the failure carries no code', async () => {
    SoftphoneAPI.getSession.mockRejectedValue(new Error('connection reset'));

    const { loadSession, errorCode } = useSoftphoneDock();
    await loadSession();

    expect(errorCode.value).toBe(SOFTPHONE_ERRORS.NETWORK);
  });

  it('reuses a fresh token instead of minting another one on every open', async () => {
    SoftphoneAPI.getSession.mockResolvedValue(SESSION);

    const { loadSession } = useSoftphoneDock();
    await loadSession();
    await loadSession();

    expect(SoftphoneAPI.getSession).toHaveBeenCalledTimes(1);
  });

  it('mints a new token when the frame asks for one', async () => {
    SoftphoneAPI.getSession.mockResolvedValue(SESSION);

    const { loadSession } = useSoftphoneDock();
    await loadSession();
    await loadSession({ force: true });

    expect(SoftphoneAPI.getSession).toHaveBeenCalledTimes(2);
  });

  it('tracks what the softphone reports and clears everything on sign-out', async () => {
    SoftphoneAPI.getSession.mockResolvedValue(SESSION);

    const { loadSession, reportFrameState, connectionState, clearSession } =
      useSoftphoneDock();
    await loadSession();
    reportFrameState(SOFTPHONE_STATES.IN_CALL);
    expect(connectionState.value).toBe(SOFTPHONE_STATES.IN_CALL);

    clearSession();
    expect(connectionState.value).toBe(SOFTPHONE_STATES.IDLE);
  });
});

describe('normalizeFrameState', () => {
  it('keeps the vocabulary the dashboard speaks', () => {
    expect(normalizeFrameState('in_call')).toBe(SOFTPHONE_STATES.IN_CALL);
    expect(normalizeFrameState('ready')).toBe(SOFTPHONE_STATES.READY);
  });

  it('understands the words a softphone is likely to use instead', () => {
    expect(normalizeFrameState('registered')).toBe(SOFTPHONE_STATES.READY);
    expect(normalizeFrameState('ONLINE')).toBe(SOFTPHONE_STATES.READY);
    expect(normalizeFrameState('connected')).toBe(SOFTPHONE_STATES.READY);
    expect(normalizeFrameState('ringing')).toBe(SOFTPHONE_STATES.IN_CALL);
    expect(normalizeFrameState('unregistered')).toBe(
      SOFTPHONE_STATES.LOGIN_REQUIRED
    );
    expect(normalizeFrameState('logged_out')).toBe(
      SOFTPHONE_STATES.LOGIN_REQUIRED
    );
    expect(normalizeFrameState('failed')).toBe(SOFTPHONE_STATES.ERROR);
  });

  it('returns null for a word it does not know, so it cannot wipe a good state', () => {
    expect(normalizeFrameState('warp-speed')).toBeNull();
    expect(normalizeFrameState('')).toBe(SOFTPHONE_STATES.IDLE);
    expect(normalizeFrameState(undefined)).toBe(SOFTPHONE_STATES.IDLE);
  });

  it('does not let an unknown word overwrite what we are already showing', () => {
    const { reportFrameState, connectionState } = useSoftphoneDock();

    reportFrameState('registered');
    expect(connectionState.value).toBe(SOFTPHONE_STATES.READY);

    reportFrameState('warp-speed');
    expect(connectionState.value).toBe(SOFTPHONE_STATES.READY);
  });
});

describe('messages relayed up from a nested frame', () => {
  const frameWindow = { name: 'our-frame' };
  const options = { frameWindow, allowedOrigins: ALLOWED_ORIGINS };
  const relayedFrom = (overrides = {}) => ({
    source: { name: 'the softphone inside the wrapper' },
    origin: 'https://soft.egytelecoms.com',
    data: {
      type: SOFTPHONE_MESSAGES.STATE,
      state: 'registered',
      relayed: true,
    },
    ...overrides,
  });

  it('accepts it, so a softphone that lives one frame deeper still reaches the dashboard', () => {
    expect(parseFrameMessage(relayedFrom(), options)).toEqual({
      type: SOFTPHONE_MESSAGES.STATE,
      state: 'registered',
      relayed: true,
    });
  });

  it('refuses it when the origin is not on the allowlist, relayed or not', () => {
    expect(
      parseFrameMessage(
        relayedFrom({ origin: 'https://somewhere.else.test' }),
        options
      )
    ).toBeNull();
  });

  it('refuses an unmarked message from a window that is not our frame', () => {
    const unmarked = relayedFrom();
    delete unmarked.data.relayed;

    expect(parseFrameMessage(unmarked, options)).toBeNull();
  });
});
