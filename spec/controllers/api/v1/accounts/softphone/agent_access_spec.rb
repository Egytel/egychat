require 'rails_helper'

# The softphone flag is an access-control boundary: only administrators may hand an agent a
# softphone session, so only administrators may set it.
RSpec.describe 'Agent softphone access', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:target) { create(:user, account: account, role: :agent, softphone_enabled: false) }
  let(:url) { "/api/v1/accounts/#{account.id}/agents/#{target.id}" }

  it 'lets an administrator mark an agent for the softphone' do
    patch url, params: { agent: { softphone_enabled: true } }, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    expect(target.reload.softphone_enabled).to be true
  end

  it 'lets an administrator take it away again' do
    target.update!(softphone_enabled: true)

    patch url, params: { agent: { softphone_enabled: false } }, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    expect(target.reload.softphone_enabled).to be false
  end

  it 'ignores the flag when a plain agent sends it' do
    patch url, params: { agent: { softphone_enabled: true } }, headers: agent.create_new_auth_token, as: :json

    expect(target.reload.softphone_enabled).to be false
  end

  it 'exposes the flag to the signed-in user so the dashboard can decide whether to render the dock' do
    target.update!(softphone_enabled: true)

    get "/api/v1/accounts/#{account.id}/agents", headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    payload = response.parsed_body.find { |item| item['id'] == target.id }
    expect(payload['softphone_enabled']).to be true
  end
end
