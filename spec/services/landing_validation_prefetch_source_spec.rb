require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe LandingValidationPrefetchSource do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "approved") }
  let(:workflow) { Workflows::LandingValidation.instantiate(job: job) }

  def run_git(path, *args)
    output, status = Open3.capture2e("git", *args, chdir: path.to_s)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?

    output
  end

  def create_source_repository(path)
    run_git(path, "init", "-q", "-b", "main")
    File.write(path.join("source.txt"), "immutable source\n")
    run_git(path, "add", "source.txt")
    run_git(path, "-c", "user.name=Spec", "-c", "user.email=spec@example.test", "commit", "-q", "-m", "source")
  end

  it "persists a bundle that reproduces the exact published source identity" do
    source_path = Pathname.new(Dir.mktmpdir("landing-prefetch-source"))
    checkout_path = Pathname.new(Dir.mktmpdir("landing-prefetch-checkout"))
    create_source_repository(source_path)
    source_sha = run_git(source_path, "rev-parse", "HEAD").strip
    tree_sha = run_git(source_path, "rev-parse", "HEAD^{tree}").strip

    snapshot = described_class.publish!(
      source_workflow: workflow,
      child_workflow: workflow,
      path: source_path,
      source_sha: source_sha,
      tree_sha: tree_sha,
      git: GitRunner.new
    )
    FileUtils.rm_rf(source_path)
    run_git(checkout_path, "init", "-q", "-b", "main")

    described_class.with_bundle(workflow, snapshot.id) do |persisted, bundle_path|
      expect(persisted).to eq(snapshot)
      run_git(checkout_path, "fetch", "--no-tags", bundle_path, "HEAD")
    end

    expect(run_git(checkout_path, "rev-parse", "FETCH_HEAD").strip).to eq(source_sha)
    expect(run_git(checkout_path, "rev-parse", "FETCH_HEAD^{tree}").strip).to eq(tree_sha)
  ensure
    FileUtils.rm_rf(source_path) if source_path
    FileUtils.rm_rf(checkout_path) if checkout_path
  end

  it "rejects publication when the source moved after its identity was recorded" do
    source_path = Pathname.new(Dir.mktmpdir("landing-prefetch-source"))
    create_source_repository(source_path)
    tree_sha = run_git(source_path, "rev-parse", "HEAD^{tree}").strip

    expect {
      described_class.publish!(
        source_workflow: workflow,
        child_workflow: workflow,
        path: source_path,
        source_sha: "stale-source-sha",
        tree_sha: tree_sha,
        git: GitRunner.new
      )
    }.to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /source changed/)

    expect(workflow.source_snapshots).to be_empty
  ensure
    FileUtils.rm_rf(source_path) if source_path
  end

  it "releases the child-owned snapshot and bundle" do
    snapshot = WorkflowSourceSnapshots.record!(workflow: workflow, creator_step: workflow.steps.first,
      source_sha: "abc", tree_sha: "tree", source_ref: "prefetch-bundle:#{workflow.id}")
    snapshot.source_bundle.attach(io: StringIO.new("bundle"), filename: "source.bundle")

    expect { described_class.release!(workflow) }.to change(WorkflowSourceSnapshot, :count).by(-1)
    expect(ActiveStorage::Attachment.where(record_type: "WorkflowSourceSnapshot", record_id: snapshot.id)).not_to exist
  end

  %w[succeeded failed cancelled].each do |state|
    it "releases retained source material after child #{state}" do
      allow(WorkflowWorkspace).to receive(:cleanup_for).with(workflow).and_return(true)
      workflow.update_columns(state: state, cleaned_up_at: Time.current)
      snapshot = WorkflowSourceSnapshots.record!(workflow: workflow, creator_step: workflow.steps.first,
        source_sha: "abc", tree_sha: "tree", source_ref: "prefetch-bundle:#{workflow.id}")
      snapshot.source_bundle.attach(io: StringIO.new("bundle"), filename: "source.bundle")

      workflow.cleanup_workspace!

      expect(WorkflowSourceSnapshot.where(id: snapshot.id)).not_to exist
    end
  end
end
