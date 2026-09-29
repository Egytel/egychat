# The wiring between one Chatwoot account and one Laravel/Asterisk box.
#
# A pair is a key and a secret:
#   account_key - which Chatwoot account this box belongs to (shown on both sides)
#   secret      - the credential Chatwoot presents when it authenticates to the box server-to-server.
#                 The same value is what the box uses to sign the call events it posts back, so one
#                 leak covers both directions - accepted deliberately, for a single credential to
#                 rotate and one place to get it wrong.
#
# Stored sealed with the app's own secret_key_base rather than relying on ActiveRecord::Encryption
# being configured (it is not, on this installation). A database dump alone is therefore not enough
# to authenticate as the pairing.
class Softphone::Connection < ApplicationRecord
  # namespaced model: without this Rails derives "connections" from the class name
  self.table_name = 'softphone_connections'

  SECRET_BYTES = 32

  belongs_to :account

  validates :pbx_url, :account_key, presence: true
  validate :pbx_url_is_https

  before_validation :normalize_pbx_url
  before_validation :ensure_account_key, on: :create

  class << self
    def encryptor
      @encryptor ||= ActiveSupport::MessageEncryptor.new(
        ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base).generate_key('softphone-connections', 32)
      )
    end

    def generate_secret
      SecureRandom.hex(SECRET_BYTES)
    end

    # What an operator sees after the value has been shown once: enough to tell two secrets apart,
    # not enough to reconstruct one.
    def fingerprint(secret)
      return nil if secret.blank?

      Digest::SHA256.hexdigest(secret.to_s).first(8)
    end
  end

  def secret
    decrypt(secret_ciphertext)
  end

  def secret=(value)
    self.secret_ciphertext = seal(value)
  end

  def secret_fingerprint
    self.class.fingerprint(secret)
  end

  # The page the dock frames, and the origin it is allowed to post to.
  def widget_url
    "#{pbx_url}#{widget_path}"
  end

  def origin
    uri = URI.parse(pbx_url.to_s)
    default_port = uri.scheme == 'https' ? 443 : 80

    "#{uri.scheme}://#{uri.host}#{uri.port && uri.port != default_port ? ":#{uri.port}" : ''}"
  rescue URI::InvalidURIError
    nil
  end

  def usable?
    enabled? && pbx_url.present? && account_key.present? && secret.present?
  end

  private

  def seal(value)
    return nil if value.blank?

    self.class.encryptor.encrypt_and_sign(value.to_s)
  end

  def decrypt(ciphertext)
    return nil if ciphertext.blank?

    self.class.encryptor.decrypt_and_verify(ciphertext)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def normalize_pbx_url
    self.pbx_url = pbx_url.to_s.strip.chomp('/') if pbx_url.present?
    self.widget_path = "/#{widget_path.to_s.strip.delete_prefix('/')}" if widget_path.present?
  end

  def pbx_url_is_https
    return if pbx_url.blank?

    errors.add(:pbx_url, 'must be an https url') unless pbx_url.start_with?('https://')
  end

  def ensure_account_key
    self.account_key ||= "acct-#{SecureRandom.hex(8)}"
  end
end
