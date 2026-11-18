require "rails_helper"

RSpec.describe PluginDesiredState::SigningKey do
  around do |example|
    previous = ENV.delete("SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY")
    example.run
  ensure
    previous ? ENV["SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY"] = previous : ENV.delete("SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY")
  end

  before do
    AppSetting.current.update!(plugin_manifest_signing_key: nil)
  end

  it "generates and stores a key when none exists" do
    key = described_class.generate!

    expect(AppSetting.current.reload.plugin_manifest_signing_key).to be_present
    expect(described_class.current.public_key).to eq(key.public_key)
  end

  it "refuses to overwrite an existing signing key" do
    original = described_class.generate!
    encoded = AppSetting.current.reload.plugin_manifest_signing_key

    expect { described_class.generate! }.to raise_error(described_class::KeyAlreadyExists)
    expect(AppSetting.current.reload.plugin_manifest_signing_key).to eq(encoded)
    expect(described_class.current.public_key).to eq(original.public_key)
  end

  it "does not persist a generated key that conflicts with the configured public key" do
    ENV["SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY"] = Base64.strict_encode64(Ed25519::SigningKey.generate.verify_key.to_bytes)

    expect { described_class.generate! }.to raise_error(described_class::PublicKeyMismatch)
    expect(AppSetting.current.reload.plugin_manifest_signing_key).to be_blank
  end

  it "generates the key once when current is called before setup" do
    first = described_class.current
    second = described_class.current

    expect(second.public_key).to eq(first.public_key)
  end
end
