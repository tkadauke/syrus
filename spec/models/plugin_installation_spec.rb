require "rails_helper"

RSpec.describe PluginInstallation do
  let(:release) do
    PluginRelease.create!(
      name: "calendar", version: "1.0.0", content_digest: "a" * 64,
      source: "bundled", trust_label: "operator", size_bytes: 0
    )
  end

  it "seeds roles and desired_since and schedules publication after commit" do
    installation = nil

    expect {
      installation = described_class.create!(plugin_name: release.name, plugin_release: release)
    }.to have_enqueued_job(PluginDesiredStatePublishJob).on_queue("control_plane")

    expect(installation.roles).to eq([])
    expect(installation.desired_since).to be_present
  end

  it "requires the installation name to match its release" do
    installation = described_class.new(plugin_name: "mail", plugin_release: release)

    expect(installation).not_to be_valid
    expect(installation.errors[:plugin_name]).to include("must match the release name")
  end

  it "requires roles to be non-empty strings" do
    installation = described_class.new(
      plugin_name: release.name, plugin_release: release, roles: [ "worker", "" ]
    )

    expect(installation).not_to be_valid
    expect(installation.errors[:roles]).to include("must be a list of non-empty strings")
  end

  it "allows only one installation per plugin name" do
    described_class.create!(plugin_name: release.name, plugin_release: release)
    duplicate = described_class.new(plugin_name: release.name, plugin_release: release)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:plugin_name]).to include("has already been taken")
  end

  it "does not require a configured signing key at the write call site" do
    AppSetting.current.update!(plugin_manifest_private_key_pem: nil)

    expect {
      described_class.create!(plugin_name: release.name, plugin_release: release)
    }.not_to raise_error
  end
end
