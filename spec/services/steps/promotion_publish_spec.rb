require "rails_helper"
require "ostruct"

RSpec.describe Steps::PromotionPublish do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Promote develop into main"
    )
  end
  let(:workflow) do
    Workflows::Promotion.instantiate(
      job: job,
      artifacts: { "promotion_source_branch" => "develop", "promotion_target_branch" => "main" }
    )
  end
  let(:step) { workflow.steps.find_by!(kind: "promotion_publish") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "promotion") }
  let(:handler) { described_class.new(run) }
  let(:branch_name) { "syrus/promote-develop-main-#{job.id}" }
  let(:workspace) do
    instance_double(WorkflowWorkspace, setup: nil, branch_name: branch_name, path: Pathname.new("/tmp/workspace"))
  end
  let(:git) { instance_double(GitRunner) }
  let(:client) { instance_double(GithubClient) }

  def stub_policy(mode:, approval_required: false)
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, promotion_mode: mode, requires_operator_approval_for_promotion?: approval_required)
    )
  end

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:access_token).and_return("token")
    allow(client).to receive(:open_pull_request_for_head).and_return(nil)
    allow(repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
  end

  describe "mode: direct" do
    before { stub_policy(mode: "direct") }

    it "pushes straight onto the target branch, records a promotion JobPrLink, and closes the job" do
      allow(git).to receive(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/main", chdir: "/tmp/workspace")

      handler.call

      expect(git).to have_received(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/main", chdir: "/tmp/workspace")
      link = job.pr_links.find_by!(role: JobPrLink::ROLE_PROMOTION)
      expect(link.source_ref).to eq("develop")
      expect(link.target_ref).to eq("main")
      expect(link.pr_number).to be_nil
      expect(link.metadata).to eq("pr_state" => "merged")
      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("promotion_landed")
    end

    it "raises StepFailed when the target branch moved since the promotion started" do
      allow(git).to receive(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/main", chdir: "/tmp/workspace")
        .and_raise(GitRunner::GitError.new(%w[push], 1, "! [rejected] HEAD -> main (fetch first)"))

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /main moved since this promotion started/)
      expect(job.pr_links.find_by(role: JobPrLink::ROLE_PROMOTION)).to be_nil
      expect(job.reload).not_to be_closed
    end
  end

  describe "mode: auto_pr" do
    before do
      allow(git).to receive(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/#{branch_name}", chdir: "/tmp/workspace")
      allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: 501))
    end

    it "opens the PR and auto-merges it when operator approval is not required" do
      stub_policy(mode: "auto_pr", approval_required: false)
      allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))

      handler.call

      expect(client).to have_received(:create_pull_request).with(
        repository.slug, base: "main", head: "#{repository.owner}:#{branch_name}",
        title: "Promote develop into main",
        body: a_string_including(PrProvenanceMarker.stamp(kind: "syrus_promotion", job: job))
      )
      expect(client).to have_received(:merge_pull_request).with(
        repository.slug, 501, commit_title: "Promote develop into main via Syrus", merge_method: "merge"
      )
      link = job.pr_links.find_by!(role: JobPrLink::ROLE_PROMOTION)
      expect(link.pr_number).to eq(501)
      expect(link.metadata).to eq("pr_state" => "merged")
      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("promotion_landed")
    end

    it "opens the PR but leaves it for manual merge when operator approval is required" do
      stub_policy(mode: "auto_pr", approval_required: true)

      handler.call

      expect(client).to have_received(:create_pull_request)
      link = job.pr_links.find_by!(role: JobPrLink::ROLE_PROMOTION)
      expect(link.pr_number).to eq(501)
      expect(link.metadata).to eq("pr_state" => "open")
      expect(job.reload).not_to be_closed
    end

    it "reuses an already-recorded promotion PR instead of opening a duplicate" do
      stub_policy(mode: "auto_pr", approval_required: true)
      JobPrLink.record!(
        job: job, role: JobPrLink::ROLE_PROMOTION,
        source_repository_id: repository.id, source_ref: "develop",
        target_repository_id: repository.id, target_ref: "main",
        pr_number: 501, metadata: { "pr_state" => "open" }
      )

      handler.call

      expect(client).not_to have_received(:create_pull_request)
    end
  end

  describe "mode: manual_pr" do
    before do
      stub_policy(mode: "manual_pr", approval_required: false)
      allow(git).to receive(:run).with("push", "https://push.example/repo.git", "HEAD:refs/heads/#{branch_name}", chdir: "/tmp/workspace")
      allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: 777))
      allow(client).to receive(:merge_pull_request)
    end

    it "never auto-merges, even when operator approval is not required" do
      handler.call

      expect(client).not_to have_received(:merge_pull_request)
      link = job.pr_links.find_by!(role: JobPrLink::ROLE_PROMOTION)
      expect(link.metadata).to eq("pr_state" => "open")
      expect(job.reload).not_to be_closed
    end
  end
end
