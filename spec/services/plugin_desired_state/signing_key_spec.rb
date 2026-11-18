require "rails_helper"

RSpec.describe PluginDesiredState::SigningKey do
  it "generates an encrypted private key and returns its distributable public key" do
    public_pem = described_class.generate!
    settings = AppSetting.current.reload
    private_key = OpenSSL::PKey.read(settings.plugin_manifest_private_key_pem)
    public_key = OpenSSL::PKey.read(public_pem)
    payload = "manifest"
    signature = private_key.sign(nil, payload)

    expect(public_key.verify(nil, signature, payload)).to be(true)
    expect(settings.ciphertext_for(:plugin_manifest_private_key_pem)).not_to include("PRIVATE KEY")
  end

  it "loads the public key from configuration when supplied" do
    configured = OpenSSL::PKey.generate_key("ED25519")
    stub_const("ENV", ENV.to_h.merge(described_class::PUBLIC_KEY_ENV => configured.public_to_pem))

    expect(described_class.public_key.public_to_der).to eq(configured.public_to_der)
  end
end
