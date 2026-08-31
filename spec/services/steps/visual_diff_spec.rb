require "rails_helper"

RSpec.describe Steps::VisualDiff do
  it "pairs baseline screenshots by title and falls back to capture order" do
    workflow = Workflow.create!(job: Factories.job_record, trigger_kind: "visual_diff")
    after_artifacts = [
      { "title" => "Dashboard", "image_url" => "/after-dashboard.png", "type" => "after-1" },
      { "title" => "Settings", "image_url" => "/after-settings.png", "type" => "after-2" }
    ]
    baselines = [
      { "type" => "before-settings", "title" => "Settings", "payload" => { "image_url" => "/before-settings.png" } },
      { "type" => "before-dashboard", "title" => "Dashboard", "payload" => { "image_url" => "/before-dashboard.png" } }
    ]

    pairs = described_class::VisualDiffPairs.new(
      workflow: workflow,
      after_artifacts: after_artifacts,
      baseline_entries: baselines
    ).pairs

    expect(pairs.map { |pair| [ pair["title"], pair.dig("before", "image_url"), pair.dig("after", "image_url") ] }).to eq([
      [ "Dashboard", "/before-dashboard.png", "/after-dashboard.png" ],
      [ "Settings", "/before-settings.png", "/after-settings.png" ]
    ])
  end

  it "returns no pairs when baseline screenshots are missing" do
    workflow = Workflow.create!(job: Factories.job_record, trigger_kind: "visual_diff")

    pairs = described_class::VisualDiffPairs.new(
      workflow: workflow,
      after_artifacts: [ { "title" => "Dashboard", "image_url" => "/after.png" } ],
      baseline_entries: []
    ).pairs

    expect(pairs).to be_empty
  end
end
