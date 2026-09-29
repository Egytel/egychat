# Hands the dashboard what it needs to open the softphone dock.
#
# Two shapes, because the wiring moved from a shared signing secret to a per-account pairing:
#
#   * a configured pair: this asks the Laravel box for a one-time code (see Softphone::LaravelClient)
#     and returns the box's own softphone page with that code appended. The box provisions it, so
#     the agent's SIP credentials never pass through Chatwoot and the dock has no token to hold.
#   * no pair yet: the original behaviour, a short-lived HS256 token in the URL fragment, which the
#     box verifies with the installation-wide secret. Still here so an account that has not been
#     wired up keeps working exactly as it did.
#
# Refusals, on purpose:
#   * 404 softphone_not_configured - the dock is switched off or half-configured
#   * 403 softphone_disabled       - this agent has not been marked as a softphone user
#   * 429 rate_limited             - too many sessions asked for in a row
class Api::V1::Accounts::Softphone::SessionsController < Api::V1::Accounts::BaseController
  RATE_LIMIT = 10
  RATE_WINDOW = 1.minute
  RATE_LIMIT_KEY = 'softphone:session:'.freeze

  before_action :ensure_softphone_available
  before_action :ensure_agent_enabled
  before_action :ensure_rate_limit

  def create
    return render_legacy_session unless pairing&.usable?

    handoff = Softphone::LaravelClient.new(connection: pairing).fetch_handoff(Current.user.email)

    return render json: { error: handoff[:error] || :pbx_unreachable }, status: :bad_gateway if handoff[:error]

    render json: session_payload.merge(
      softphone_url: "#{pairing.widget_url}?handoff=#{handoff[:handoff]}",
      allowed_origins: [pairing.origin].compact,
      expires_in: handoff[:expires_in] || Softphone::Config.token_ttl,
      pairing: pairing.account_key
    )
  end

  private

  def pairing
    @pairing ||= Softphone::Config.connection_for(Current.account)
  end

  def session_payload
    {
      account_id: Current.account.id,
      agent: {
        id: Current.user.id,
        name: Current.user.available_name,
        email: Current.user.email
      }
    }
  end

  def render_legacy_session
    render json: session_payload.merge(
      softphone_url: Softphone::Config.iframe_url_for(Current.account),
      allowed_origins: Softphone::Config.allowed_origins_for(Current.account),
      token: mint_token,
      expires_in: Softphone::Config.token_ttl
    )
  end

  # Deliberately not named `token`: the auth concerns in BaseController define that name, and
  # a method with the same name there shadows this one (that bug returned the auth headers
  # instead of a JWT).
  def mint_token
    @mint_token ||= Softphone::TokenService.new(user: Current.user, account: Current.account).mint
  end

  def ensure_softphone_available
    return if pairing&.usable? || Softphone::Config.available?

    render json: { error: 'softphone_not_configured' }, status: :not_found
  end

  def ensure_agent_enabled
    return if Current.user.softphone_enabled?

    render json: { error: 'softphone_disabled' }, status: :forbidden
  end

  # A session is an identity assertion, so cap how often one agent can ask for one: a stolen
  # dashboard session should not be able to farm credentials quietly.
  def ensure_rate_limit
    key = "#{RATE_LIMIT_KEY}#{Current.user.id}"
    count = Rails.cache.read(key).to_i
    return render json: { error: 'rate_limited' }, status: :too_many_requests if count >= RATE_LIMIT

    Rails.cache.write(key, count + 1, expires_in: RATE_WINDOW)
  end
end
