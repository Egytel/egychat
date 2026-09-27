# Reads the softphone-dock settings in one place.
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

  class << self
    def enabled?
      GlobalConfigService.load(ENABLED_KEY, false).to_s == 'true'
    end

    def iframe_url
      GlobalConfigService.load(IFRAME_URL_KEY, '').to_s.strip.chomp('/')
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
  end
end
