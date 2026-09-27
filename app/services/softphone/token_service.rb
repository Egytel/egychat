# Mints and verifies the short-lived identity tokens the dashboard hands to the softphone.
#
# Chatwoot is the identity provider here: the token says "this agent, in this account, right
# now". It is deliberately tiny and disposable - the softphone exchanges it for its own
# session, so the token's only job is to prove who the agent is.
class Softphone::TokenService
  AUDIENCE = 'hatif-softphone'.freeze
  ALGORITHM = 'HS256'.freeze
  SEEN_JTI_PREFIX = 'softphone:jti:'.freeze
  SEEN_JTI_TTL = 10.minutes

  pattr_initialize [:user!, :account!]

  def mint
    issued_at = Time.current

    JWT.encode(claims(issued_at), secret, ALGORITHM)
  end

  # Returns the claims when the token is genuine, nil when it is not. Expiry, a wrong
  # signature, a wrong issuer/audience and a malformed token are all "not genuine" from the
  # caller's point of view, so they collapse into nil.
  def self.verify(token)
    return nil if token.blank? || Softphone::Config.shared_secret.blank?

    claims, = JWT.decode(token, Softphone::Config.shared_secret, true, decode_options)
    claims.with_indifferent_access
  rescue JWT::DecodeError
    nil
  end

  # Single use: the first caller to claim a jti wins, everyone else gets false. Keeps a
  # replayed token from opening a second session.
  def self.consume!(jti)
    return false if jti.blank?

    Rails.cache.write("#{SEEN_JTI_PREFIX}#{jti}", true, expires_in: SEEN_JTI_TTL, unless_exist: true)
  end

  def self.decode_options
    {
      algorithm: ALGORITHM,
      aud: AUDIENCE,
      verify_aud: true,
      iss: frontend_url,
      verify_iss: true
    }
  end

  # The issuer is this installation's own public origin, so a token minted by another box
  # (dev vs prod) is not accepted here.
  def self.frontend_url
    ENV.fetch('FRONTEND_URL', nil).to_s.chomp('/')
  end

  private

  def claims(issued_at)
    {
      iss: self.class.frontend_url,
      aud: AUDIENCE,
      sub: user.id.to_s,
      jti: SecureRandom.uuid,
      iat: issued_at.to_i,
      exp: (issued_at + Softphone::Config.token_ttl).to_i,
      account_id: account.id,
      agent_id: user.id,
      email: user.email,
      name: user.available_name
    }
  end

  def secret
    Softphone::Config.shared_secret
  end
end
