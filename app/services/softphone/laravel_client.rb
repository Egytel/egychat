# Talks to the Laravel/Asterisk box for one account pairing.
#
# The dock no longer mints a JWT the box has to verify. Chatwoot instead authenticates to the box
# server-to-server with the pairing's key and secret, names the agent by email, and receives a
# ONE-TIME code. The dock frames the box's own softphone page with that code, the box exchanges it
# for the agent's provisioning, and the phone registers. No SIP credential passes through Chatwoot.
class Softphone::LaravelClient
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  pattr_initialize [:connection!]

  # Derived from the page path, so a pairing only has to record the page:
  #   /dashboard/phone-widget -> /dashboard/phone-widget/agent-login
  def login_url
    "#{connection.widget_url}/agent-login"
  end

  # Returns { handoff:, expires_in:, user: } on success, or { error: <symbol> }.
  # The body is never logged: it carries the pairing secret.
  def fetch_handoff(email)
    response = http.post(login_url) do |request|
      request.headers['Content-Type'] = 'application/json'
      request.body = {
        account_key: connection.account_key,
        secret: connection.secret,
        email: email
      }.to_json
    end

    interpret(response)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
    Rails.logger.warn("[softphone] pair #{connection.account_key}: #{e.class} reaching #{login_url}")
    { error: :pbx_unreachable }
  rescue JSON::ParserError
    { error: :pbx_bad_response }
  end

  private

  def http
    @http ||= Faraday.new do |faraday|
      faraday.options.open_timeout = OPEN_TIMEOUT
      faraday.options.timeout = READ_TIMEOUT
    end
  end

  def interpret(response)
    body = response.body.present? ? JSON.parse(response.body) : {}

    case response.status
    when 200
      { handoff: body['handoff'], expires_in: body['expires_in'], user: body['user'] }
    when 401
      { error: :pair_credentials_rejected }
    when 404
      { error: :no_crm_user_for_email }
    else
      { error: :"pbx_error_#{response.status}" }
    end
  end
end
