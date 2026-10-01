require "rails_helper"

RSpec.describe CognitiveReview::McpToolSet do
  let(:run) { Factories.job_with_run(step_attrs: { kind: "post_implementation_review" }).initial_run }
  let(:context) { McpToolContext.from_run(run) }

  before do
    PluginRecord.find_or_create_by!(name: "cognitive_review").update!(enabled: true, default_enabled: false, disableable: true)
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

  it "stores submitted notes as durable rows scoped to the current diff version" do
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
    note = CognitiveReview::Note.find_by!(run: run, diff_review_version: version)
    expect(note).to have_attributes(
      path: "app/models/job.rb",
      side: "new",
      start_line: 12,
      end_line: 14,
      new_start_line: 12,
      new_end_line: 14,
      title: "State transition edge",
      explanation: "Operator should inspect whether the new transition is reachable.",
      confidence: 0.82
    )
    expect(note.source_metadata).to include(
      "diff_review_version_id" => version.id,
      "base_sha" => "base",
      "head_sha" => "head"
    )
  end

  it "submits notes idempotently for the current run and version" do
    DiffReviewVersions::Creator.call(
      job: run.job,
      workflow: run.workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    params = {
      notes: [
        {
          path: "app/models/job.rb",
          side: "new",
          start_line: 12,
          end_line: 12,
          title: "State transition edge",
          explanation: "Initial explanation.",
          reason_codes: [ "state" ],
          priority: "high"
        }
      ]
    }

    2.times { described_class.new.handle("submit_cognitive_review_notes", params, { run: run }) }

    expect(CognitiveReview::Note.where(run: run).count).to eq(1)
    expect(CognitiveReview::Note.last).to have_attributes(explanation: "Initial explanation.", priority: "high")
  end

  it "accepts an empty no-debt submission without requiring a diff version" do
    response = described_class.new.handle("submit_cognitive_review_notes", { notes: [] }, { run: run })

    expect(response).not_to be_error
    expect(CognitiveReview::Note.where(run: run)).to be_empty
  end

  it "rejects malformed ranges without creating notes" do
    DiffReviewVersions::Creator.call(
      job: run.job,
      workflow: run.workflow,
      run: run,
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
            start_line: 0,
            title: "Bad range",
            explanation: "This should not save."
          }
        ]
      },
      { run: run }
    )

    expect(response).to be_error
    expect(CognitiveReview::Note.count).to eq(0)
  end

  it "returns a structured validation error for non-object note entries" do
    response = described_class.new.handle(
      "submit_cognitive_review_notes",
      { notes: [ "not an object" ] },
      { run: run }
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include("notes[0] must be an object")
    expect(CognitiveReview::Note.count).to eq(0)
  end

  it "withholds the tool while the plugin is disabled" do
    PluginRecord.find_by!(name: "cognitive_review").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(described_class.available_for_context?(context)).to be(false)
    expect(described_class.tool_definitions(context: context)).to eq([])
  end
end
