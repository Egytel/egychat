require 'rails_helper'

RSpec.describe Softphone::TokenService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, name: 'Agent One') }
  let(:secret) { 'spec-softphone-secret' }
  let(:issuer) { 'https://chats.example.com' }
  let(:service) { described_class.new(user: user, account: account) }

  before do
    allow(Softphone::Config).to receive(:shared_secret).and_return(secret)
    allow(described_class).to receive(:frontend_url).and_return(issuer)
  end

  describe '#mint' do
    it 'signs an HS256 token for the softphone audience, valid for the configured ttl' do
      claims, header = JWT.decode(service.mint, secret, true, algorithm: 'HS256')

      expect(header['alg']).to eq('HS256')
      expect(claims['iss']).to eq(issuer)
      expect(claims['aud']).to eq(Softphone::TokenService::AUDIENCE)
      expect(claims['exp'] - claims['iat']).to eq(Softphone::Config::TOKEN_TTL)
    end

    it 'carries the agent identity the softphone matches on' do
      claims, = JWT.decode(service.mint, secret, true, algorithm: 'HS256')

      expect(claims['sub']).to eq(user.id.to_s)
      expect(claims['agent_id']).to eq(user.id)
      expect(claims['account_id']).to eq(account.id)
      expect(claims['email']).to eq(user.email)
      expect(claims['jti']).to be_present
    end

    it 'issues a different jti every time' do
      first, = JWT.decode(service.mint, secret, true, algorithm: 'HS256')
      second, = JWT.decode(service.mint, secret, true, algorithm: 'HS256')

      expect(first['jti']).not_to eq(second['jti'])
    end
  end

  describe '.verify' do
    it 'accepts a token it minted' do
      claims = described_class.verify(service.mint)

      expect(claims['email']).to eq(user.email)
    end

    it 'rejects a token signed with another secret' do
      foreign = JWT.encode({ aud: 'hatif-softphone', iss: issuer, exp: 10.minutes.from_now.to_i }, 'someone-elses-secret', 'HS256')

      expect(described_class.verify(foreign)).to be_nil
    end

    it 'rejects an expired token' do
      expired = JWT.encode(
        { aud: 'hatif-softphone', iss: issuer, exp: 1.minute.ago.to_i, jti: SecureRandom.uuid },
        secret, 'HS256'
      )

      expect(described_class.verify(expired)).to be_nil
    end

    it 'rejects a token minted for another installation' do
      other_box = JWT.encode(
        { aud: 'hatif-softphone', iss: 'https://chats.other.example.com', exp: 10.minutes.from_now.to_i },
        secret, 'HS256'
      )

      expect(described_class.verify(other_box)).to be_nil
    end

    it 'rejects a token meant for another audience' do
      other_audience = JWT.encode(
        { aud: 'some-other-app', iss: issuer, exp: 10.minutes.from_now.to_i },
        secret, 'HS256'
      )

      expect(described_class.verify(other_audience)).to be_nil
    end

    it 'returns nil for a blank token' do
      expect(described_class.verify(nil)).to be_nil
      expect(described_class.verify('')).to be_nil
    end
  end

  describe '.consume!' do
    before do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    it 'lets the first caller through and refuses a replay' do
      jti = SecureRandom.uuid

      expect(described_class.consume!(jti)).to be true
      expect(described_class.consume!(jti)).to be false
    end

    it 'refuses a blank jti' do
      expect(described_class.consume!(nil)).to be false
    end
  end
end
