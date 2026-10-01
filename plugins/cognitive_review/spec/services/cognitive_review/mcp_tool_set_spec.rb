require "rails_helper"

RSpec.describe CognitiveReview::McpToolSet do
  let(:run) { Factories.job_with_run(step_attrs: { kind: "post_implementation_review" }).initial_run }
  let(:context) { McpToolContext.from_run(run) }

  before do
    PluginRecord.find_or_create_by!(name: "cognitive_review").update!(enabled: true, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "exposes submit_cognitive_review_notes to post-implementation review runs" do
    expect(described_class.available_for_context?(context)).to be(true)
    expect(described_class.tool_definitions(context: context).pluck(:name)).to eq([ "submit_cognitive_review_notes" ])
  end

  it "withholds the tool from ordinary implementation runs" do
    implement_run = Factories.job_with_run(step_attrs: { kind: "implement" }).initial_run

    expect(described_class.available_for_context?(McpToolContext.from_run(implement_run))).to be(false)
  end

  it "stores submitted notes in the workflow artifact" do
    version = DiffReviewVersions::Creator.call(
      job: run.job,
      workflow: run.workflow,
      run: nil,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    response = described_class.new.handle(
      "submit_cognitive_review_notes",
      {
        notes: [
          {
            path: "app/models/job.rb",
            side: "new",
            start_line: 12,
            end_line: 14,
            title: "State transition edge",
            body: "Operator should inspect whether the new transition is reachable.",
            category: "state",
            confidence: 0.82
          }
        ]
      },
      { run: run }
    )

    expect(response).not_to be_error
    entry = run.workflow.reload.artifact(CognitiveReview::Artifact::KEY).last
    expect(entry).to include(
      "diff_review_version_id" => version.id,
      "base_sha" => "base",
      "head_sha" => "head"
    )
    expect(entry["notes"]).to contain_exactly(
      hash_including(
        "path" => "app/models/job.rb",
        "side" => "new",
        "start_line" => 12,
        "end_line" => 14,
        "title" => "State transition edge",
        "confidence" => 0.82
      )
    )
  end
end
