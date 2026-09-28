/* global axios */
import ApiClient from './ApiClient';

/**
 * The dashboard's door to the softphone dock.
 *
 * One endpoint so far: the session, which returns the iframe url, the origins allowed to
 * receive the token and the short-lived identity token itself (Softphone::TokenService on
 * the backend). The dashboard asks for a token every time the dock opens, and again when
 * the softphone reports the one it has is about to expire.
 */
class SoftphoneAPI extends ApiClient {
  constructor() {
    super('softphone', { accountScoped: true });
  }

  getSession() {
    return axios.post(`${this.url}/session`).then(r => r.data);
  }
}

export default new SoftphoneAPI();
