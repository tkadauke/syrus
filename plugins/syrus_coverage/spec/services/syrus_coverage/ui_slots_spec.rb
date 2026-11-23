require "rails_helper"
require_relative "../../support/snapshot_factory"

RSpec.describe SyrusCoverage::UiSlots do
  let(:job) { Factories.job }

  it "contributes the card with the latest coverage artifact, trimmed to what the card renders" do
    job.workflows.first.set_artifact!("coverage", { "summary" => { "lines_pct" => 90.0 }, "diff_annotations" => { "a.rb" => { "1" => "covered" } }, "hit_map" => {} })

    panels = described_class.ui_slots(slot: "job.detail", context: { job: job })

    expect(panels.size).to eq(1)
    expect(panels.first).to include(id: "syrus_coverage.card", component: "syrus_coverage/CoverageCard")
    expect(panels.first[:props][:coverage]).to eq({ "summary" => { "lines_pct" => 90.0 } })
  end

  it "contributes no card for a Job without a coverage artifact" do
    expect(described_class.ui_slots(slot: "job.detail", context: { job: job })).to eq([])
  end

  it "contributes the trend sparkline to the repository page" do
    panels = described_class.ui_slots(slot: "repository.detail", context: { repository: job.repository })

    expect(panels.map { |panel| panel[:component] }).to eq([ "syrus_coverage/CoverageSparkline" ])
  end

  it "ignores other slots and is withheld while the plugin is disabled" do
    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: {})).to eq([])

    PluginRecord.find_or_create_by!(name: "syrus_coverage").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    expect(App::UiSlotsPayload.panels_for(slot: "repository.detail", context: { repository: job.repository }).map { |p| p[:component] })
      .not_to include("syrus_coverage/CoverageSparkline")
  ensure
    PluginRecord.find_by(name: "syrus_coverage")&.update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end
end
