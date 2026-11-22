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

  it "round-trips the selected registry when release identities collide" do
    admin = Factories.user(admin: true)
    allow(SsrfGuard).to receive(:safe_host?).and_return(true)
    first = PluginRegistry.create!(name: "first", url: "https://first.example.test")
    second = PluginRegistry.create!(name: "second", url: "https://second.example.test")
    attributes = { name: "acme_weather", version: "1.0.0", content_digest: "b" * 64,
      source: "registry", trust_label: "verified", size_bytes: 1 }
    PluginRelease.create!(**attributes, plugin_registry: first)
    selected = PluginRelease.create!(**attributes, plugin_registry: second)
    selected.archive.attach(io: StringIO.new("x"), filename: "acme_weather.archive")
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    allow(Syrus::PluginPackage::TrustStore).to receive(:for_release)
      .and_return(instance_double(Syrus::PluginPackage::TrustStore, revoked?: false))
    PluginInstallation.create!(plugin_name: selected.name, plugin_release: selected)

    lockfile = described_class.export
    PluginInstallation.delete_all
    change = described_class.import!(lockfile, actor: admin).sole

    expect(change.plugin_release).to eq(selected)
    expect(YAML.safe_load(lockfile).fetch("plugins").sole).to include("registry" => "second")
  end
end
