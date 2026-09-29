# Reads the softphone-dock settings in one place.
#
# Two levels, because the dock was first built as a single-tenant feature and is now per-account:
#
#   * a Softphone::Connection row for the account (the PBX it dials through, its account key and
#     its two secrets) - what new installations should use;
#   * the global installation configs below - what the first version used, still honoured so an
#     account without a connection row keeps working exactly as before.
#
# The dock only works when it is switched on, points at an https page and has a secret to
# sign session tokens with. Anything less is a misconfiguration, and `available?` is what
# the session endpoint reports as a 404 instead of handing out an unusable token.
class Softphone::Config
  ENABLED_KEY = 'SOFTPHONE_ENABLED'.freeze
  IFRAME_URL_KEY = 'SOFTPHONE_IFRAME_URL'.freeze
  ALLOWED_ORIGINS_KEY = 'SOFTPHONE_ALLOWED_ORIGINS'.freeze
  SHARED_SECRET_ENV = 'SOFTPHONE_SHARED_SECRET'.freeze
  TOKEN_TTL = 120

  # Every instance we run sits under one registrable domain, so trusting the domain is simpler and
  # less brittle than trusting exact origins. A constant rather than a setting: it is not expected to
  # change, and a setting here would be a security-relevant one to get wrong.
  TRUSTED_DOMAIN = 'egytelecoms.com'.freeze

  class << self
    def enabled?
      GlobalConfigService.load(ENABLED_KEY, false).to_s == 'true'
    end

    def iframe_url
      GlobalConfigService.load(IFRAME_URL_KEY, '').to_s.strip.chomp('/')
    end

    # https only, and only our own domain or a subdomain of it. Used anywhere we are about to hand a
    # token to an origin.
    def trusted_origin?(candidate)
      origin = candidate.to_s.strip.chomp('/')
      return false unless origin.start_with?('https://')

      host = origin.delete_prefix('https://').split(':').first.to_s.downcase

      host == TRUSTED_DOMAIN || host.end_with?(".#{TRUSTED_DOMAIN}")
    end

    # Only https origins are accepted: the dock posts an identity token to this origin, and
    # a plain-http page would let anyone on the network read it.
    def allowed_origins
      GlobalConfigService.load(ALLOWED_ORIGINS_KEY, '').to_s.split(/[\s,]+/).filter_map do |origin|
        normalized = origin.strip.chomp('/')
        normalized.presence if normalized.start_with?('https://')
      end.uniq
    end

    def shared_secret
      ENV.fetch(SHARED_SECRET_ENV, nil).to_s.presence
    end

    def token_ttl
      TOKEN_TTL
    end

    def available?
      enabled? && iframe_url.present? && shared_secret.present?
    end

    # --- per-account wiring (preferred when configured) -------------------------------------

    def connection_for(account)
      return nil if account.blank?

      Softphone::Connection.find_by(account_id: account.id)
    end

    def enabled_for?(account)
      connection = connection_for(account)

      connection.present? ? (enabled? && connection.usable?) : available?
    end

    def iframe_url_for(account)
      connection_for(account)&.widget_url.presence || iframe_url
    end

    def allowed_origins_for(account)
      origin = connection_for(account)&.origin

      origin.present? && trusted_origin?(origin) ? [origin] : allowed_origins
    end

    # Signing key for this account's session tokens: the connection's own secret, else the
    # installation-wide one.
    def shared_secret_for(account)
      connection_for(account)&.secret.presence || shared_secret
    end

    # Which Chatwoot account the PBX should consider itself paired with. Travels in the token as
    # a claim, and is what the PBX uses to pick the secret it verifies with.
    def account_key_for(account)
      connection_for(account)&.account_key.presence
    end

    # One secret covers both directions, so "can we sign events?" is "is the pairing configured?".
    def events_usable_for?(account)
      connection_for(account)&.secret.present? || false
    end
  end
end
