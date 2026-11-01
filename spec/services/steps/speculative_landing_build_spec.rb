require "rails_helper"
require "tmpdir"
require "open3"

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

  def run_git(path, *args)
    output, status = Open3.capture2e("git", *args, chdir: path.to_s)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?

    output
  end

  def initialize_source_repository
    run_git(source_path, "init", "-q", "-b", "main")
    File.write(source_path.join("predicted-base.txt"), "recorded base\n")
    run_git(source_path, "add", "predicted-base.txt")
    run_git(source_path, "-c", "user.name=Spec", "-c", "user.email=spec@example.test", "commit", "-q", "-m", "predicted base")
  end

  def publish_and_cleanup_source!(handler)
    initialize_source_repository
    source_head = run_git(source_path, "rev-parse", "HEAD").strip
    source_tree = run_git(source_path, "rev-parse", "HEAD^{tree}").strip
    snapshot = LandingValidationPrefetchSource.publish!(
      source_workflow: source_workflow,
      child_workflow: handler.workflow,
      path: source_path,
      source_sha: source_head,
      tree_sha: source_tree,
      git: GitRunner.new
    )
    handler.workflow.update!(artifacts: handler.workflow.artifacts.merge(
      "prefetch_source_snapshot_id" => snapshot.id,
      "prefetch_source_head_sha" => source_head,
      "prefetch_source_tree_sha" => source_tree
    ))
    allow(WorkflowWorkspace).to receive(:cleanup_for).with(source_workflow) do |workflow|
      FileUtils.rm_rf(source_path)
      workflow.update_columns(cleaned_up_at: Time.current)
      true
    end
    source_workflow.update_columns(state: "succeeded", finished_at: Time.current)
    source_workflow.cleanup_workspace!

    expect(source_path).not_to exist
    [ source_head, source_tree ]
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

    source_head, source_tree = publish_and_cleanup_source!(handler)
    run_git(workspace_path, "init", "-q", "-b", "main")

    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).and_return("")
    expect(git).to receive(:run).with("fetch", "--no-tags", kind_of(String), "HEAD", chdir: workspace_path.to_s) do |_, _, bundle_path, _, **|
      run_git(workspace_path, "fetch", "--no-tags", bundle_path, "HEAD")
    end
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: workspace_path.to_s).and_return("candidate-head\n")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: workspace_path.to_s) { run_git(workspace_path, "rev-parse", "FETCH_HEAD") }
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD^{tree}", chdir: workspace_path.to_s) { run_git(workspace_path, "rev-parse", "FETCH_HEAD^{tree}") }
    allow(git).to receive(:run).with("rev-parse", "HEAD^{tree}", chdir: workspace_path.to_s).and_return("tree-sha\n")

    handler.call
    expect(run_git(workspace_path, "rev-parse", "FETCH_HEAD").strip).to eq(source_head)
    expect(run_git(workspace_path, "rev-parse", "FETCH_HEAD^{tree}").strip).to eq(source_tree)
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

    source_head, source_tree = publish_and_cleanup_source!(handler)
    run_git(workspace_path, "init", "-q", "-b", "main")

    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubAuthenticatedGit).to receive(:run).and_yield("https://example.test/repo.git")
    allow(git).to receive(:run).and_return("")
    expect(git).to receive(:run).with("fetch", "--no-tags", kind_of(String), "HEAD", chdir: workspace_path.to_s) do |_, _, bundle_path, _, **|
      run_git(workspace_path, "fetch", "--no-tags", bundle_path, "HEAD")
    end
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: workspace_path.to_s) { run_git(workspace_path, "rev-parse", "FETCH_HEAD") }
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD^{tree}", chdir: workspace_path.to_s) { run_git(workspace_path, "rev-parse", "FETCH_HEAD^{tree}") }
    allow(git).to receive(:run).with("status", "--porcelain", chdir: workspace_path.to_s).and_return("")
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: workspace_path.to_s).and_return("train-head\n")
    allow(git).to receive(:run).with("rev-parse", "HEAD^{tree}", chdir: workspace_path.to_s).and_return("tree-sha\n")

    handler.call
    expect(run_git(workspace_path, "rev-parse", "FETCH_HEAD").strip).to eq(source_head)
    expect(run_git(workspace_path, "rev-parse", "FETCH_HEAD^{tree}").strip).to eq(source_tree)
  end

  it "rejects a source SHA mismatch instead of rebuilding from another base" do
    handler = build_handler(Steps::SpeculativeLandingBuild, "speculative_landing_build", candidate, source_artifacts)
    snapshot = double(source_sha: "newer-head", tree_sha: "source-tree")
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).and_return("candidate-head\n")
    allow(LandingValidationPrefetchSource).to receive(:with_bundle).and_yield(snapshot, "/tmp/source.bundle")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /does not match/)
  end

  it "rejects a fetched source identity mismatch for ordinary validation" do
    handler = build_handler(Steps::SpeculativeLandingBuild, "speculative_landing_build", candidate, source_artifacts)
    snapshot = double(source_sha: "source-head", tree_sha: "source-tree")
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).and_return("")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: workspace_path.to_s).and_return("newer-head\n")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD^{tree}", chdir: workspace_path.to_s).and_return("newer-tree\n")
    allow(LandingValidationPrefetchSource).to receive(:with_bundle).and_yield(snapshot, "/tmp/source.bundle")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /snapshot mismatch/)
  end

  it "rejects a fetched source identity mismatch for merge-train validation" do
    member = Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 3, branch_name: "syrus/member")
    handler = build_handler(
      Steps::SpeculativeMergeTrainBuild,
      "speculative_merge_train_build",
      member,
      source_artifacts.merge("prefetch_merge_train_member_job_ids" => [ member.id ]),
      trigger_kind: "merge_train_validation"
    )
    snapshot = double(source_sha: "source-head", tree_sha: "source-tree")
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(git).to receive(:run).and_return("")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: workspace_path.to_s).and_return("newer-head\n")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD^{tree}", chdir: workspace_path.to_s).and_return("newer-tree\n")
    allow(LandingValidationPrefetchSource).to receive(:with_bundle).and_yield(snapshot, "/tmp/source.bundle")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /snapshot mismatch/)
  end
end
