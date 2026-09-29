/* The Hatif softphone relay.
 *
 * Include this on any page of the softphone that sits between the dashboard and the frame
 * that really runs the phone (a Laravel shell around the client, for example). It does three
 * things and nothing else:
 *
 *   1. carries messages from a nested frame UP to the dashboard, marked `relayed: true`
 *      (the dashboard accepts a relayed message on the strength of its origin);
 *   2. carries the dashboard's messages (the token, logout, later screen-pop or dial
 *      commands) DOWN into every nested frame;
 *   3. if the page was loaded with `#hatif_token=…`, clears it from the address bar and
 *      forwards it down, so a nested client is authenticated even though the fragment
 *      technically landed on the wrapper.
 *
 * The dashboard side of this contract lives in
 * app/javascript/dashboard/composables/useSoftphoneDock.js, and it only ever accepts a
 * message whose origin is on the allowlist the backend returned for that session.
 */
(() => {
  const PREFIX = 'hatif:';

  // softphone -> dashboard (bubbles up)
  const UP = ['hatif:ready', 'hatif:auth-result', 'hatif:state', 'hatif:auth-expired'];
  // dashboard -> softphone (fans out down)
  const DOWN = ['hatif:auth', 'hatif:logout', 'hatif:context', 'hatif:dial'];

  const nestedFrames = () =>
    [...document.querySelectorAll('iframe')].map(frame => frame.contentWindow).filter(Boolean);

  const isOurs = data =>
    data && typeof data === 'object' && String(data.type || '').startsWith(PREFIX);

  const forwardDown = data => {
    nestedFrames().forEach(win => {
      try {
        win.postMessage(data, '*');
      } catch (error) {
        /* a frame that refused the message is not our problem */
      }
    });
  };

  const forwardUp = data => {
    if (window.parent === window) return;

    try {
      window.parent.postMessage({ ...data, relayed: true }, '*');
    } catch (error) {
      /* nothing to do: the dashboard will simply not hear about it */
    }
  };

  window.addEventListener('message', event => {
    const data = event.data;
    if (!isOurs(data)) return;

    if (UP.includes(data.type)) forwardUp(data);
    else if (DOWN.includes(data.type)) forwardDown(data);
  });

  // A fragment that landed here belongs to whoever is nested inside us.
  const match = (window.location.hash || '').match(/hatif_token=([^&]+)/);
  if (match) {
    const token = decodeURIComponent(match[1]);
    window.history.replaceState(
      null,
      '',
      window.location.pathname + window.location.search
    );
    // give the nested frames a tick to attach their listeners
    setTimeout(
      () => forwardDown({ type: 'hatif:auth', token, relayed: true }),
      0
    );
  }
})();
