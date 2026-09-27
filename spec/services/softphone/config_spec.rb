require 'rails_helper'

RSpec.describe Softphone::Config do
  let(:iframe_url) { 'https://soft.egytelecoms.com/' }

  before do
    create(:installation_config, name: 'SOFTPHONE_ENABLED', value: 'true')
    create(:installation_config, name: 'SOFTPHONE_IFRAME_URL', value: iframe_url)
    create(:installation_config, name: 'SOFTPHONE_ALLOWED_ORIGINS', value: 'https://soft.egytelecoms.com, http://insecure.example.com https://other.example.com/')
  end

  around do |example|
    with_modified_env(SOFTPHONE_SHARED_SECRET: 'super-secret-value') { example.run }
  end

  it 'reads the flag, the url and the origins from the installation config' do
    expect(described_class.enabled?).to be true
    expect(described_class.iframe_url).to eq('https://soft.egytelecoms.com')
    expect(described_class.allowed_origins).to contain_exactly('https://soft.egytelecoms.com', 'https://other.example.com')
  end

  it 'is available only with a flag, a url and a secret' do
    expect(described_class.available?).to be true

    with_modified_env(SOFTPHONE_SHARED_SECRET: '') do
      expect(described_class.available?).to be false
    end
  end

  it 'ignores non-https origins, because the token travels to that origin' do
    expect(described_class.allowed_origins).not_to include('http://insecure.example.com')
  end
end
