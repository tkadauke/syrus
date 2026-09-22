require "rails_helper"

RSpec.describe PluginRuntime::Holds do
  let!(:record) do
    PluginRecord.find_or_create_by!(name: "plugin_runtime").tap do |rec|
      rec.update!(config: { "settings" => { "some" => "value" } })
    end
  end

  it "holds and releases services, keeping the plugin's settings intact" do
    described_class.hold!("git-mirror")
    described_class.hold!("git-mirror")
    described_class.hold!("search")

    expect(described_class.all).to eq(%w[git-mirror search])
    expect(described_class).to be_held("git-mirror")

    described_class.release!("git-mirror")

    expect(described_class.all).to eq(%w[search])
    expect(record.reload.config["settings"]).to eq("some" => "value")
  end

  # Saving the plugin's settings form merges only the "settings" key.
  it "survives the settings form being saved" do
    described_class.hold!("git-mirror")
    record.reload.update!(config: record.config.merge("settings" => { "some" => "other" }))

    expect(described_class).to be_held("git-mirror")
  end

  it "forgets holds on services no plugin wants any more" do
    described_class.hold!("git-mirror")
    described_class.hold!("gone")

    described_class.prune!(%w[git-mirror])

    expect(described_class.all).to eq(%w[git-mirror])
  end
end
