require 'rails_helper'

RSpec.describe 'Softphone session API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent, softphone_enabled: true) }
  let(:unmarked_agent) { create(:user, account: account, role: :agent) }
  let(:secret) { 'spec-softphone-secret' }
  let(:url) { "/api/v1/accounts/#{account.id}/softphone/session" }
  let(:body) { response.parsed_body }

  before do
    allow(Softphone::Config).to receive(:enabled?).and_return(true)
    allow(Softphone::Config).to receive(:iframe_url).and_return('https://soft.egytelecoms.com')
    allow(Softphone::Config).to receive(:allowed_origins).and_return(['https://soft.egytelecoms.com'])
    allow(Softphone::Config).to receive(:shared_secret).and_return(secret)
    allow(Softphone::Config).to receive(:available?).and_return(true)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  it 'hands a marked agent the dock configuration' do
    post url, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(body['softphone_url']).to eq('https://soft.egytelecoms.com')
    expect(body['allowed_origins']).to eq(['https://soft.egytelecoms.com'])
    expect(body['expires_in']).to eq(Softphone::Config::TOKEN_TTL)
    expect(body['agent']).to include('id' => agent.id, 'email' => agent.email)
  end

  it 'hands that agent a token the softphone can verify for them' do
    post url, headers: agent.create_new_auth_token, as: :json

    claims, header = JWT.decode(body['token'], secret, true, algorithm: 'HS256')
    expect(header['alg']).to eq('HS256')
    expect(claims['email']).to eq(agent.email)
    expect(claims['account_id']).to eq(account.id)
    expect(claims['aud']).to eq(Softphone::TokenService::AUDIENCE)
  end

  it 'refuses an agent who is not marked as a softphone user' do
    post url, headers: unmarked_agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error']).to eq('softphone_disabled')
  end

  it 'reports a switched-off or half-configured dock as not found' do
    allow(Softphone::Config).to receive(:available?).and_return(false)

    post url, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']).to eq('softphone_not_configured')
  end

  it 'rate limits token minting per agent' do
    Api::V1::Accounts::Softphone::SessionsController::RATE_LIMIT.times do
      post url, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
    end

    post url, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body['error']).to eq('rate_limited')
  end
end
