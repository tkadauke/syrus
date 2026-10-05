require "rails_helper"

RSpec.describe CognitiveReview::McpToolSet do
  let(:run) { Factories.job_with_run(step_attrs: { kind: "post_implementation_review" }).initial_run }
  let(:context) { McpToolContext.from_run(run) }

  before do
    PluginRecord.find_or_create_by!(name: "cognitive_review").update!(enabled: true, default_enabled: false, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "exposes submit_review_notes to post-implementation review runs" do
    expect(described_class.available_for_context?(context)).to be(true)
    expect(described_class.tool_definitions(context: context).pluck(:name)).to eq([ "submit_review_notes" ])
  end

  it "advertises submit_review_notes through the real workflow MCP sidecar for review runs" do
    tool_names = workflow_sidecar_tool_names(run)

    expect(tool_names).to include("submit_review_notes")
  end

  it "withholds the tool from ordinary implementation runs" do
    implement_run = Factories.job_with_run(step_attrs: { kind: "implement" }).initial_run

    expect(described_class.available_for_context?(McpToolContext.from_run(implement_run))).to be(false)
    expect(workflow_sidecar_tool_names(implement_run)).not_to include("submit_review_notes")
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
      "submit_review_notes",
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
    artifact_entry = run.workflow.reload.artifact(CognitiveReview::Artifact::KEY).last
    expect(artifact_entry).to include(
      "diff_review_version_id" => version.id,
      "notes" => [ include("path" => "app/models/job.rb") ]
    )
  end

  it "stores retry review notes against the existing final diff version when the retry workflow has no version" do
    job = Factories.job_with_run(step_attrs: { kind: "implement" })
    implementation_workflow = job.latest_workflow
    implementation_run = job.initial_run
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: implementation_workflow,
      run: implementation_run,
      base_sha: "implementation-base",
      head_sha: "implementation-head",
      files: [
        { path: "app/models/job.rb", status: "modified", additions: 3, deletions: 1 }
      ],
      reason: "initial"
    )
    DiffReviewVersion.create!(
      job: job,
      version_index: DiffReviewVersion.next_index_for(job),
      base_sha: "main",
      head_sha: "main",
      source_key: "legacy-empty-all-changes",
      label: "All changes",
      reason: "source_diff",
      files_snapshot: [],
      metadata: { "range_kind" => "all_changes" }
    )
    retry_workflow = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: job.agent_provider)
    Step.create!(workflow: retry_workflow, kind: "prepare", position: 0)
    Step.create!(workflow: retry_workflow, kind: "pr_open", position: 1)
    review_step = Step.create!(workflow: retry_workflow, kind: "post_implementation_review", position: 2)
    review_run = Run.create!(job: job, step: review_step, trigger_kind: "retry", agent_provider: job.agent_provider)

    response = described_class.new.handle(
      "submit_review_notes",
      {
        notes: [
          {
            path: "app/models/job.rb",
            side: "new",
            start_line: 27,
            title: "Lifecycle edge",
            explanation: "Operator should inspect the retry lifecycle assumption."
          }
        ]
      },
      { run: review_run }
    )

    expect(response).not_to be_error
    expect(CognitiveReview::Note.find_by!(run: review_run)).to have_attributes(
      diff_review_version: version,
      path: "app/models/job.rb",
      explanation: "Operator should inspect the retry lifecycle assumption."
    )
    expect(retry_workflow.reload.artifact(CognitiveReview::Artifact::KEY).last)
      .to include("diff_review_version_id" => version.id)
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

    2.times { described_class.new.handle("submit_review_notes", params, { run: run }) }

    expect(CognitiveReview::Note.where(run: run).count).to eq(1)
    expect(CognitiveReview::Note.last).to have_attributes(explanation: "Initial explanation.", priority: "high")
  end

  it "stores an empty no-debt submission as durable evidence for the current diff version" do
    version = DiffReviewVersions::Creator.call(
      job: run.job,
      workflow: run.workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    response = described_class.new.handle("submit_review_notes", { notes: [] }, { run: run })

    expect(response).not_to be_error
    expect(CognitiveReview::Note.where(run: run)).to be_empty
    expect(run.workflow.reload.artifact(CognitiveReview::Artifact::KEY).last).to include(
      "diff_review_version_id" => version.id,
      "notes" => []
    )
  end

  it "rejects an empty submission when no diff review version exists" do
    response = described_class.new.handle("submit_review_notes", { notes: [] }, { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("No diff review version is available")
    expect(run.workflow.reload.artifact(CognitiveReview::Artifact::KEY)).to be_nil
  end

  it "accepts the legacy cognitive-review tool name for compatibility" do
    DiffReviewVersions::Creator.call(
      job: run.job,
      workflow: run.workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    response = described_class.new.handle("submit_cognitive_review_notes", { notes: [] }, { run: run })

    expect(response).not_to be_error
    expect(response.content.first[:text]).to include("Saved 0 review note")
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
      "submit_review_notes",
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
      "submit_review_notes",
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

  def workflow_sidecar_tool_names(run)
    server = Mcp::Sidecar.workflow(run_id: run.id).build_server
    initialize_request = { jsonrpc: "2.0", id: 0, method: "initialize", params: {} }.to_json
    server.handle_json(initialize_request)
    request = { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json
    response = JSON.parse(server.handle_json(request), symbolize_names: true)
    response.fetch(:result).fetch(:tools).map { |tool| tool.fetch(:name) }
  end
end
