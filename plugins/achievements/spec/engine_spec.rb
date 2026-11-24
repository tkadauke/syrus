require "rails_helper"

RSpec.describe Achievements do
  let(:manifest) { Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "achievements" } }

  it "registers as a disableable, default-off plugin" do
    expect(manifest).to be_present
    expect(manifest.disableable?).to be(true)
    expect(manifest.default_enabled).to be(false)
  end

  it "reports an invalid registry at boot without raising" do
    bad = Achievements::Registry.new([ Achievements::Catalog.definitions.first ] * 2)
    allow(Achievements::Registry).to receive(:default).and_return(bad)
    allow(Rails.logger).to receive(:error)

    expect { Achievements::Callbacks.on_boot }.not_to raise_error
    expect(Rails.logger).to have_received(:error).with(/duplicate key/)
  end

  it "stays quiet for the valid catalog" do
    allow(Rails.logger).to receive(:error)
    Achievements::Callbacks.on_boot
    expect(Rails.logger).not_to have_received(:error)
  end

  it "keeps plugin-owned tables prefixed and adds no achievement columns to core tables" do
    expect(Achievements::Unlock.table_name).to start_with("achievements_")
    expect(Achievements::Acknowledgment.table_name).to start_with("achievements_")
    %w[jobs epics users].each do |table|
      expect(ActiveRecord::Base.connection.columns(table).map(&:name).grep(/achievement/)).to be_empty
    end
  end

  it "runs its only job on the plugin queue, which workers consume" do
    jobs = Dir[Rails.root.join("plugins/achievements/app/jobs/**/*.rb")].map { |path| File.basename(path, ".rb") }
    expect(jobs).to eq([ "evaluation_retry_job" ])
    expect(Achievements::EvaluationRetryJob.new.queue_name).to eq("plugin_achievements")
  end
end
