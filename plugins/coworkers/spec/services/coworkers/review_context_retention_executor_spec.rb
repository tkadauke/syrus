require "rails_helper"
require "tmpdir"

RSpec.describe Coworkers::ReviewContextRetentionExecutor do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-retention", workspace_repo: repository.remote_url)
  end
  let(:job) { Factories.job(user: owner, repository:) }
  let(:step) { Step.create!(workflow: job.latest_workflow, kind: "coworker_review", position: 99) }
  let(:run) { step.runs.create!(job:, trigger_kind: "initial", agent_provider: "codex", model: "test") }
  let(:evidence) do
    ReviewEvidence.create!(run:, workflow: run.workflow, step:, reviewer: coworker, review_kind: "coworker",
      provider: "codex", model: "test", reviewed_base_sha: "a" * 40, reviewed_head_sha: "b" * 40,
      canonical_diff_sha256: "c" * 64, prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1")
  end
  let(:definition) do
    instance_double(RetentionPolicyRegistry::Definition, retention_window: 30.days,
      model_class: Coworkers::ReviewContext, scope_name: :retention_candidates)
  end

  around do |example|
    Dir.mktmpdir("coworker-review-retention") do |directory|
      @root = Pathname(directory)
      previous_data_root = ENV["SYRUS_DATA_ROOT"]
      ENV["SYRUS_DATA_ROOT"] = directory
      example.run
    ensure
      ENV["SYRUS_DATA_ROOT"] = previous_data_root
    end
  end

  def create_context(workspace_path)
    Coworkers::ReviewContext.create!(run:, review_evidence: evidence, coworker:,
      manifest: { "protected_prompt" => { "sha256" => "safe" } }, exact_context: { "protected_prompt" => "restricted" },
      workspace_path: workspace_path.to_s, created_at: 31.days.ago)
  end

  it "deletes the run-owned checkout before tombstoning restricted evidence" do
    workspace = Coworkers::ReviewWorkspace.path_for(run)
    FileUtils.mkdir_p(workspace)
    workspace.join("memory.md").write("private memory")
    context = create_context(workspace)

    result = described_class.new(definition).call

    expect(result.deleted_count).to eq(1)
    expect(workspace).not_to exist
    expect(context.reload).to have_attributes(persistence_state: "tombstoned", exact_context: "[tombstoned]",
      workspace_path: "[tombstoned]", manifest: { "protected_prompt" => { "sha256" => "safe" } })
  end

  it "tombstones safely when the run-owned checkout is already missing" do
    context = create_context(Coworkers::ReviewWorkspace.path_for(run))

    expect { described_class.new(definition).call }.to change { context.reload.persistence_state }.to("tombstoned")
  end

  it "refuses to delete an unrelated directory and preserves its recovery pointer" do
    unrelated = @root.join("unrelated")
    FileUtils.mkdir_p(unrelated)
    unrelated.join("keep.txt").write("keep")
    context = create_context(unrelated)

    expect { described_class.new(definition).call }.to raise_error(Coworkers::ReviewWorkspace::UnsafePath)
    expect(unrelated.join("keep.txt")).to exist
    expect(context.reload.persistence_state).to eq("prepared")
    expect(context.workspace_path).to eq(unrelated.to_s)
  end

  it "refuses a symlinked run-owned path without touching its target" do
    workspace = Coworkers::ReviewWorkspace.path_for(run)
    outside = @root.join("outside")
    FileUtils.mkdir_p([ workspace.parent, outside ])
    outside.join("keep.txt").write("keep")
    File.symlink(outside, workspace)
    context = create_context(workspace)

    expect { described_class.new(definition).call }.to raise_error(Coworkers::ReviewWorkspace::UnsafePath, /symlink/)
    expect(outside.join("keep.txt")).to exist
    expect(context.reload.persistence_state).to eq("prepared")
  end
end
