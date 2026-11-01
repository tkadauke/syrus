require "rails_helper"
require "tmpdir"

RSpec.describe "speculative landing build steps" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
  let(:source_job) { Factories.job_record(user: user, repository: repository, state: "landing", pr_number: 1, branch_name: "syrus/source") }
  let(:candidate) { Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 2, branch_name: "syrus/candidate") }
  let(:source_workflow) { Workflow.create!(job: source_job, trigger_kind: "auto_merge") }
  let(:source_path) { Pathname.new(Dir.mktmpdir("speculative-source")) }
  let(:workspace_path) { Pathname.new(Dir.mktmpdir("speculative-target")) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: nil, path: workspace_path) }
  let(:git) { instance_double(GitRunner) }

  after do
    FileUtils.rm_rf(source_path.to_s)
    FileUtils.rm_rf(workspace_path.to_s)
  end

  def build_handler(klass, kind, job, artifacts, trigger_kind: "landing_validation")
    workflow = Workflow.create!(job: job, trigger_kind: trigger_kind, artifacts: artifacts)
    step = Step.create!(workflow: workflow, kind: kind, position: 0)
    run = Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind)
    klass.new(run).tap do |handler|
      allow(handler).to receive(:workspace).and_return(workspace)
    end
  end

  def source_artifacts
    {
      "prefetch_source_workflow_id" => source_workflow.id,
      "prefetch_source_snapshot_id" => 123,
      "prefetch_source_head_sha" => "source-head",
      "prefetch_source_tree_sha" => "source-tree"
    }
  end

  it "builds an ordinary validation from the child-owned source bundle" do
    handler = build_handler(
      Steps::SpeculativeLandingBuild,
      "speculative_landing_build",
      candidate,
      source_artifacts.merge("prefetch_candidate_head_sha" => "candidate-head")
    )

    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).and_return("")
    snapshot = double(source_sha: "source-head", tree_sha: "source-tree")
    allow(LandingValidationPrefetchSource).to receive(:with_bundle).and_yield(snapshot, "/tmp/source.bundle")
    expect(git).to receive(:run).with("fetch", "--no-tags", "/tmp/source.bundle", "HEAD", chdir: workspace_path.to_s)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: workspace_path.to_s).and_return("candidate-head\n")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: workspace_path.to_s).and_return("source-head\n")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD^{tree}", chdir: workspace_path.to_s).and_return("source-tree\n")
    allow(git).to receive(:run).with("rev-parse", "HEAD^{tree}", chdir: workspace_path.to_s).and_return("tree-sha\n")

    FileUtils.rm_rf(source_path)
    handler.call
  end

  it "builds a merge-train validation from the child-owned source bundle" do
    member = Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 3, branch_name: "syrus/member")
    handler = build_handler(
      Steps::SpeculativeMergeTrainBuild,
      "speculative_merge_train_build",
      member,
      source_artifacts.merge("prefetch_merge_train_member_job_ids" => [ member.id ]),
      trigger_kind: "merge_train_validation"
    )

    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubAuthenticatedGit).to receive(:run).and_yield("https://example.test/repo.git")
    allow(git).to receive(:run).and_return("")
    snapshot = double(source_sha: "source-head", tree_sha: "source-tree")
    allow(LandingValidationPrefetchSource).to receive(:with_bundle).and_yield(snapshot, "/tmp/source.bundle")
    expect(git).to receive(:run).with("fetch", "--no-tags", "/tmp/source.bundle", "HEAD", chdir: workspace_path.to_s)
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: workspace_path.to_s).and_return("source-head\n")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD^{tree}", chdir: workspace_path.to_s).and_return("source-tree\n")
    allow(git).to receive(:run).with("status", "--porcelain", chdir: workspace_path.to_s).and_return("")
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: workspace_path.to_s).and_return("train-head\n")
    allow(git).to receive(:run).with("rev-parse", "HEAD^{tree}", chdir: workspace_path.to_s).and_return("tree-sha\n")

    FileUtils.rm_rf(source_path)
    handler.call
  end

  it "rejects a source SHA mismatch instead of rebuilding from another base" do
    handler = build_handler(Steps::SpeculativeLandingBuild, "speculative_landing_build", candidate, source_artifacts)
    snapshot = double(source_sha: "newer-head", tree_sha: "source-tree")
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).and_return("candidate-head\n")
    allow(LandingValidationPrefetchSource).to receive(:with_bundle).and_yield(snapshot, "/tmp/source.bundle")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /does not match/)
  end
end
