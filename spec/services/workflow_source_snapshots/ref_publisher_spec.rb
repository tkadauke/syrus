require "rails_helper"

RSpec.describe WorkflowSourceSnapshots::RefPublisher, :ci_only do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.create!(job: job, user: job.user, trigger_kind: workflow.trigger_kind) }
  let(:workspace) { instance_double(WorkflowWorkspace, path: Pathname.new("/tmp/workspace")) }
  let(:git) { instance_double(GitRunner) }
  let(:sleeper) { class_double(Kernel, sleep: nil) }
  let(:random) { class_double(Random, rand: 0.4) }
  let(:source_sha) { "a" * 40 }
  let(:remote_ref) { "refs/syrus/source-snapshots/runs/#{run.id}" }

  before do
    allow(GithubAuthenticatedGit).to receive(:run) { |**_, &block| block.call("https://example.test/repo.git") }
  end

  def publish!
    described_class.publish!(run: run, workspace: workspace, source_sha: source_sha, remote_ref: remote_ref,
      git: git, sleeper: sleeper, random: random)
  end

  def git_error(output)
    GitRunner::GitError.new([ "push" ], 128, output)
  end

  it "retries commit_refs_rules failures and publishes the exact immutable SHA" do
    allow(git).to receive(:run).with("ls-remote", anything, remote_ref, any_args).and_return("")
    attempts = 0
    expect(git).to receive(:run).with("push", anything, "#{source_sha}:#{remote_ref}", any_args).twice do
      attempts += 1
      raise git_error("remote: fatal error in commit_refs_rules") if attempts == 1

      ""
    end

    expect(publish!).to eq(remote_ref)
    expect(sleeper).to have_received(:sleep).with(0.275).once
  end

  it "records the original error and complete retry history when transient retries are exhausted" do
    allow(git).to receive(:run).with("ls-remote", anything, remote_ref, any_args).and_return("")
    allow(git).to receive(:run).with("push", anything, "#{source_sha}:#{remote_ref}", any_args)
      .and_raise(git_error("remote: fatal error in commit_refs_rules"))

    expect { publish! }.to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /after 3 attempts/)

    evidence = workflow.reload.artifact(described_class::ARTIFACT_KEY)
    expect(evidence).to include("source_sha" => source_sha, "source_ref" => remote_ref)
    expect(evidence.fetch("attempts").map { |entry| entry["attempt"] }).to eq([ 1, 2, 3 ])
    expect(evidence.fetch("original_error")).to eq(evidence.fetch("attempts").first)
    expect(evidence.fetch("attempts").pluck("classification")).to all(eq("transient_remote_failure"))
    expect(evidence.fetch("attempts").first.fetch("message")).to include("commit_refs_rules")
  end

  it "accepts an already-published ref that matches the immutable SHA" do
    allow(git).to receive(:run).with("ls-remote", anything, remote_ref, any_args)
      .and_return("#{source_sha}\t#{remote_ref}\n")
    expect(git).not_to receive(:run).with("push", anything, anything, any_args)

    expect(publish!).to eq(remote_ref)
  end

  it "rejects an already-published ref that targets another SHA" do
    allow(git).to receive(:run).with("ls-remote", anything, remote_ref, any_args)
      .and_return("#{'b' * 40}\t#{remote_ref}\n")

    expect { publish! }.to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /points at #{'b' * 40}/)
    expect(git).not_to receive(:run).with("push", anything, anything, any_args)
  end

  it "does not retry permanent authentication failures" do
    allow(git).to receive(:run).with("ls-remote", anything, remote_ref, any_args).and_return("")
    expect(git).to receive(:run).with("push", anything, anything, any_args)
      .once.and_raise(git_error("remote: Authentication failed"))

    expect { publish! }.to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /Authentication failed/)
    expect(sleeper).not_to have_received(:sleep)
  end

  it "does not retry GitHub push-protection failures" do
    finding = GithubPushProtection::Finding.new(secret_type: "Token", commit_sha: source_sha, path: "x.rb", line: 2)
    rejected = GithubPushProtection::Rejected.new([ "push" ], 1, findings: [ finding ], ref: remote_ref)
    allow(git).to receive(:run).with("ls-remote", anything, remote_ref, any_args).and_return("")
    expect(git).to receive(:run).with("push", anything, anything, any_args).once.and_raise(rejected)

    expect { publish! }.to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /push protection/i)
    expect(sleeper).not_to have_received(:sleep)
  end
end
