# Hands the dashboard what it needs to open the softphone dock: the iframe URL plus a
# short-lived identity token for the agent who asked.
#
# Three ways this can refuse, on purpose:
#   * 404 softphone_not_configured - the dock is switched off or half-configured
#   * 403 softphone_disabled       - this agent has not been marked as a softphone user
#   * 429 rate_limited             - too many tokens asked for in a row
class Api::V1::Accounts::Softphone::SessionsController < Api::V1::Accounts::BaseController
  RATE_LIMIT = 10
  RATE_WINDOW = 1.minute
  RATE_LIMIT_KEY = 'softphone:session:'.freeze

  before_action :ensure_softphone_available
  before_action :ensure_agent_enabled
  before_action :ensure_rate_limit

  def create
    render json: {
      softphone_url: Softphone::Config.iframe_url,
      allowed_origins: Softphone::Config.allowed_origins,
      token: mint_token,
      expires_in: Softphone::Config.token_ttl,
      account_id: Current.account.id,
      agent: {
        id: Current.user.id,
        name: Current.user.available_name,
        email: Current.user.email
      }
    }
  end

  private

  # Deliberately not named `token`: the auth concerns in BaseController define that name, and
  # a method with the same name there shadows this one (that bug returned the auth headers
  # instead of a JWT).
  def mint_token
    @mint_token ||= Softphone::TokenService.new(user: Current.user, account: Current.account).mint
  end

  def ensure_softphone_available
    return if Softphone::Config.available?

    render json: { error: 'softphone_not_configured' }, status: :not_found
  end

  def ensure_agent_enabled
    return if Current.user.softphone_enabled?

    render json: { error: 'softphone_disabled' }, status: :forbidden
  end

  # A token is an identity assertion, so cap how often one agent can ask for them: a stolen
  # dashboard session should not be able to farm credentials quietly.
  def ensure_rate_limit
    key = "#{RATE_LIMIT_KEY}#{Current.user.id}"
    count = Rails.cache.read(key).to_i
    return render json: { error: 'rate_limited' }, status: :too_many_requests if count >= RATE_LIMIT

    Rails.cache.write(key, count + 1, expires_in: RATE_WINDOW)
  end
end
