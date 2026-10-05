require "rails_helper"
require "fileutils"

RSpec.describe CognitiveReview::PostImplementationReviewProvider do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_with_run(user: user, repository: repository, issue_title: "Tighten queue lifecycle") }
  let(:workflow) { job.latest_workflow }
  let(:run) { job.initial_run }

  before do
    PluginRecord.find_or_create_by!(name: "cognitive_review").update!(enabled: true, default_enabled: false, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  after do
    FileUtils.rm_rf(WorkflowWorkspace.path_for(workflow))
  end

  it "requests implementation-style workflows only while the plugin is enabled" do
    expect(described_class.review_needed?(job: job, trigger_kind: "initial")).to be(true)
    expect(described_class.review_needed?(job: job, trigger_kind: "retry")).to be(true)
    expect(described_class.review_needed?(job: job, trigger_kind: "ci_failure")).to be(false)

    PluginRecord.find_by!(name: "cognitive_review").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(described_class.review_needed?(job: job, trigger_kind: "initial")).to be(false)
  end

  it "builds a high-signal prompt around the final diff review version" do
    DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base-sha",
      head_sha: "head-sha",
      files: [
        { path: "app/models/work_unit.rb", status: "modified", additions: 8, deletions: 2 },
        { path: "db/migrate/20261001010101_add_queue_state.rb", status: "added", additions: 42, deletions: 0 }
      ]
    )

    prompt = described_class.prompt_sections(job: job, workflow: workflow, run: run).join("\n\n")

    expect(prompt).to include("Review the final implementation diff for acme/widgets and submit high-signal Review Notes.")
    expect(prompt).to include("Base/head: base-sha...head-sha")
    expect(prompt).to include("app/models/work_unit.rb (modified, +8/-2)")
    expect(prompt).to include("db/migrate/20261001010101_add_queue_state.rb (added, +42/-0)")
    expect(prompt).to include("git diff base-sha...head-sha -- <path>")
    expect(prompt).to include("Prefer no note over filler")
    expect(prompt).to include("comment-like review notes")
    expect(prompt).to include("Use Agent Memory when available")
    expect(prompt).to include("lifecycle or state-machine choices")
    expect(prompt).to include("queue behavior")
    expect(prompt).to include("migrations")
    expect(prompt).to include("concise review guidance explaining why the code is the")
    expect(prompt).to include("not a generic checklist")
    expect(prompt).to include("Submit your result with submit_review_notes")
    expect(prompt).to include("call it with an empty notes array")
    expect(prompt).to include("Do not edit files")
  end

  it "includes memory context when Agent Memory is enabled and has visible memories" do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: true, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    AgentMemory::Entry.create!(
      user: user,
      kind: "feedback",
      scope: "repository",
      scope_id: repository.id,
      content: "Focus on queue race assumptions."
    )

    prompt = described_class.prompt_sections(job: job, workflow: workflow, run: run).join("\n\n")

    expect(prompt).to include("Agent Memory context:")
    expect(prompt).to include("Focus on queue race assumptions.")
  end

  it "includes merged .syrus.yml review-note policy for the final diff files" do
    workspace_path = WorkflowWorkspace.path_for(workflow)
    FileUtils.mkdir_p(workspace_path.join("apps/web"))
    File.write(workspace_path.join(".syrus.yml"), <<~YAML)
      review_notes:
        criteria:
          - Surface shared services and final-diff resolution paths
        low_signal:
          - Do not spend notes on ordinary test bodies
    YAML
    File.write(workspace_path.join("apps/web/.syrus.yml"), <<~YAML)
      project:
        id: web
        label: Web App
      review_notes:
        criteria:
          - Surface shared frontend harness changes
        low_signal:
          - Ignore snapshots unless they alter a risk model
    YAML
    FileUtils.mkdir_p(workspace_path.join("apps/api"))
    File.write(workspace_path.join("apps/api/.syrus.yml"), <<~YAML)
      project:
        id: api
      review_notes:
        criteria:
          - Surface API adapter lifecycle changes
    YAML

    DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base-sha",
      head_sha: "head-sha",
      files: [
        { path: "apps/web/src/finalDiffResolver.ts", status: "added", additions: 24, deletions: 0 }
      ]
    )

    prompt = described_class.prompt_sections(job: job, workflow: workflow, run: run).join("\n\n")

    expect(prompt).to include("Repository Review Notes policy from .syrus.yml:")
    expect(prompt).to include("Surface shared services and final-diff resolution paths")
    expect(prompt).to include("Surface shared frontend harness changes")
    expect(prompt).not_to include("Surface API adapter lifecycle changes")
    expect(prompt).to include("Do not spend notes on ordinary test bodies")
    expect(prompt).to include("Ignore snapshots unless they alter a risk model")
    expect(prompt).to include("Web App (apps/web/.syrus.yml)")
    expect(prompt).to include("A small but architectural change deserves consideration")
    expect(prompt).to include("final-diff")
    expect(prompt).to include("Routine test implementation is usually low-signal")
    expect(prompt).to include("testing frameworks, shared harnesses, coverage boundaries, or risk")
  end

  it "falls back gracefully when memory is unavailable" do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: false, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    prompt = described_class.prompt_sections(job: job, workflow: workflow, run: run).join("\n\n")

    expect(prompt).to include("Agent Memory context: unavailable")
    expect(prompt).to include("rely on the Job prompt, repository context, and final diff")
  end

  it "requires the review-note submission tool" do
    expect(described_class.required_mcp_tools(job: job, workflow: workflow, run: run))
      .to eq([ "submit_review_notes" ])
  end
end
