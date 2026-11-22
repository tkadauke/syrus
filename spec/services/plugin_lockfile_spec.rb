require "rails_helper"

RSpec.describe PluginLockfile do
  it "round-trips canonical release identity into pending desired-state changes" do
    admin = Factories.user(admin: true)
    release = PluginRelease.create!(name: "weather", version: "1.2.3", content_digest: "a" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0)
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release)
    PluginChange.create!(plugin_name: "weather", action: "install", plugin_release: release,
      capability_manifest: { "routes" => [ "/weather" ] }, status: "confirmed", staged_by: admin,
      confirmed_by: admin, confirmed_at: Time.current)

    lockfile = described_class.export
    PluginInstallation.delete_all
    changes = described_class.import!(lockfile, actor: admin)

    expect(changes.sole).to have_attributes(plugin_name: "weather", action: "install", plugin_release: release, status: "pending")
    expect(changes.sole.capability_manifest).to eq("routes" => [ "/weather" ])
    expect(YAML.safe_load(lockfile).fetch("plugins").sole).to eq(
      "name" => "weather", "version" => "1.2.3", "digest" => "a" * 64, "source" => "bundled"
    )
  end
end
