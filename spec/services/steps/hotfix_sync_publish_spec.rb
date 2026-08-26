require "rails_helper"
require "ostruct"

RSpec.describe Steps::HotfixSyncPublish do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Sync main into develop"
    )
  end
  let(:workflow) do
    Workflows::HotfixSync.instantiate(
      job: job,
      artifacts: { "hotfix_sync_source_branch" => "main", "hotfix_sync_target_branch" => "develop" }
    )
  end
  let(:step) { workflow.steps.find_by!(kind: "hotfix_sync_publish") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "hotfix_sync") }
  let(:handler) { described_class.new(run) }
  let(:branch_name) { "syrus/hotfix-sync-main-develop-#{job.id}" }
  let(:workspace) do
    instance_double(WorkflowWorkspace, setup: nil, branch_name: branch_name, path: Pathname.new("/tmp/workspace"))
  end
  let(:git) { instance_double(GitRunner) }
  let(:client) { instance_double(GithubClient) }

  def stub_policy(mode:)
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_mode: mode)
    )
  end

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:access_token).and_return("token")
    allow(repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
  end

  describe "mode: auto" do
    before { stub_policy(mode: "auto") }

    it "pushes straight onto the target branch, records a hotfix_sync JobPrLink, and closes the job" do
      allow(git).to receive(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/develop", chdir: "/tmp/workspace")

      handler.call

      expect(git).to have_received(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/develop", chdir: "/tmp/workspace")
      link = job.pr_links.find_by!(role: JobPrLink::ROLE_HOTFIX_SYNC)
      expect(link.source_ref).to eq("main")
      expect(link.target_ref).to eq("develop")
      expect(link.pr_number).to be_nil
      expect(link.metadata).to eq("pr_state" => "merged")
      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("hotfix_sync_landed")
    end

    it "raises StepFailed when the target branch moved since the sync started" do
      allow(git).to receive(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/develop", chdir: "/tmp/workspace")
        .and_raise(GitRunner::GitError.new(%w[push], 1, "! [rejected] HEAD -> develop (fetch first)"))

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /develop moved since this hotfix sync started/)
      expect(job.pr_links.find_by(role: JobPrLink::ROLE_HOTFIX_SYNC)).to be_nil
      expect(job.reload).not_to be_closed
    end
  end

  describe "mode: auto_pr" do
    before do
      stub_policy(mode: "auto_pr")
      allow(git).to receive(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/#{branch_name}", chdir: "/tmp/workspace")
      allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: 501))
    end

    it "opens the PR and auto-merges it" do
      allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))

      handler.call

      expect(client).to have_received(:create_pull_request).with(
        repository.slug, base: "develop", head: "#{repository.owner}:#{branch_name}",
        title: "Sync main into develop", body: kind_of(String)
      )
      expect(client).to have_received(:merge_pull_request).with(
        repository.slug, 501, commit_title: "Sync main into develop via Syrus", merge_method: "merge"
      )
      link = job.pr_links.find_by!(role: JobPrLink::ROLE_HOTFIX_SYNC)
      expect(link.pr_number).to eq(501)
      expect(link.metadata).to eq("pr_state" => "merged")
      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("hotfix_sync_landed")
    end

    it "reuses an already-recorded hotfix_sync PR instead of opening a duplicate" do
      JobPrLink.record!(
        job: job, role: JobPrLink::ROLE_HOTFIX_SYNC,
        source_repository_id: repository.id, source_ref: "main",
        target_repository_id: repository.id, target_ref: "develop",
        pr_number: 501, metadata: { "pr_state" => "open" }
      )
      allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))

      handler.call

      expect(client).not_to have_received(:create_pull_request)
    end
  end

  describe "mode: manual_pr" do
    before do
      stub_policy(mode: "manual_pr")
      allow(git).to receive(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/#{branch_name}", chdir: "/tmp/workspace")
      allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: 777))
      allow(client).to receive(:merge_pull_request)
    end

    it "never auto-merges" do
      handler.call

      expect(client).not_to have_received(:merge_pull_request)
      link = job.pr_links.find_by!(role: JobPrLink::ROLE_HOTFIX_SYNC)
      expect(link.metadata).to eq("pr_state" => "open")
      expect(job.reload).not_to be_closed
    end
  end
end
