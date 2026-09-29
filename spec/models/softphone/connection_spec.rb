require 'rails_helper'

RSpec.describe Softphone::Connection do
  let(:account) { create(:account) }

  describe 'sealing the secrets' do
    it 'never stores a secret in the clear' do
      connection = described_class.create!(account: account, pbx_url: 'https://997.c6.egytelecoms.com',
                                           account_key: 'acct-test', secret: 'the-pairing-secret')

      connection.reload
      raw = connection.read_attribute(:secret_ciphertext)
      expect(raw).not_to include('the-pairing-secret')
      expect(connection.secret).to eq('the-pairing-secret')
    end

    it 'survives a tampered ciphertext without raising' do
      connection = described_class.create!(account: account, pbx_url: 'https://pbx.example.com',
                                           account_key: 'acct-test', secret: 'x' * 32)
      # rubocop:disable Rails/SkipsModelValidations -- the point is to plant a value the
      # validator would never accept, to prove decryption fails closed
      connection.update_column(:secret_ciphertext, 'garbage-looking-ciphertext')
      # rubocop:enable Rails/SkipsModelValidations
      expect(connection.reload.secret).to be_nil
    end
  end

  describe 'the address the dock frames' do
    it 'joins the pbx url and the widget path' do
      connection = described_class.new(pbx_url: 'https://997.c6.egytelecoms.com', widget_path: 'dashboard/phone-widget')
      connection.valid?
      expect(connection.widget_url).to eq('https://997.c6.egytelecoms.com/dashboard/phone-widget')
      expect(connection.origin).to eq('https://997.c6.egytelecoms.com')
    end

    it 'keeps a non-default port in the origin' do
      connection = described_class.new(pbx_url: 'https://pbx.example.com:8443')
      expect(connection.origin).to eq('https://pbx.example.com:8443')
    end
  end

  describe 'validation' do
    it 'refuses a plain-http pbx url: the token would travel in the clear' do
      connection = described_class.new(account: account, pbx_url: 'http://pbx.example.com', account_key: 'k')
      expect(connection).not_to be_valid
      expect(connection.errors[:pbx_url]).to be_present
    end

    it 'generates an account key when one is not supplied' do
      connection = described_class.create!(account: account, pbx_url: 'https://pbx.example.com')
      expect(connection.account_key).to start_with('acct-')
    end
  end

  describe 'usability' do
    it 'is not usable until it has its secret' do
      connection = described_class.new(account: account, pbx_url: 'https://pbx.example.com', account_key: 'k')
      expect(connection).not_to be_usable
      connection.secret = 'the-secret'
      expect(connection).to be_usable
    end

    it 'is not usable when switched off' do
      connection = described_class.new(account: account, pbx_url: 'https://pbx.example.com',
                                       account_key: 'k', secret: 's', enabled: false)
      expect(connection).not_to be_usable
    end
  end

  describe 'fingerprints' do
    it 'are stable, distinct per secret and short' do
      a = described_class.fingerprint('secret-a')
      b = described_class.fingerprint('secret-b')
      expect(a).to eq(described_class.fingerprint('secret-a'))
      expect(a).not_to eq(b)
      expect(a.length).to eq(8)
      expect(described_class.fingerprint(nil)).to be_nil
    end
  end
end
