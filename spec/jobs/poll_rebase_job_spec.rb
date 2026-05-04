require "rails_helper"
require "ostruct"

RSpec.describe PollRebaseJob do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job(user: user, repository: repository, issue_number: 42, pr_number: 7, branch_name: "syrus/issue-42-1") }

  # Build a Sawyer-ish PR resource using OpenStruct so the job can call
  # pr.merged, pr.state, pr.mergeable, pr.head.repo.full_name, etc.
  def pr_resource(merged: false, state: "open", mergeable: false,
                  head_repo: "acme/widgets", base_repo: "acme/widgets")
    head = OpenStruct.new(repo: OpenStruct.new(full_name: head_repo), ref: "syrus/issue-42-1")
    base = OpenStruct.new(repo: OpenStruct.new(full_name: base_repo), ref: "main")
    OpenStruct.new(merged: merged, state: state, mergeable: mergeable, head: head, base: base)
  end

  def stub_pr(pr)
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr)
  end

  describe "happy path" do
    it "creates a rebase Run when the PR is unmergeable and we own the head" do
      stub_pr(pr_resource(mergeable: false))

      expect {
        described_class.perform_now(job.id)
      }.to change { job.runs.where(trigger_kind: "rebase").count }.by(1)
    end
  end

  describe "persisting last-known mergeability for the show page" do
    before { job }   # force initial Run creation before assertions

    it "stamps pr_mergeable + checked_at on every check (true)" do
      stub_pr(pr_resource(mergeable: true))
      freeze_time do
        described_class.perform_now(job.id)
        expect(job.reload.pr_mergeable).to be true
        expect(job.pr_mergeable_checked_at).to eq(Time.current)
      end
    end

    it "stamps pr_mergeable + checked_at on every check (false)" do
      stub_pr(pr_resource(mergeable: false))
      described_class.perform_now(job.id)
      expect(job.reload.pr_mergeable).to be false
      expect(job.pr_mergeable_checked_at).to be_present
    end

    it "stamps pr_mergeable=nil when GitHub is still computing" do
      stub_pr(pr_resource(mergeable: nil))
      described_class.perform_now(job.id)
      expect(job.reload.pr_mergeable).to be_nil
      expect(job.pr_mergeable_checked_at).to be_present
    end

    it "still stamps when the PR is merged or closed (so the badge surfaces the terminal state)" do
      stub_pr(pr_resource(merged: true, state: "closed", mergeable: true))
      described_class.perform_now(job.id)
      expect(job.reload.pr_mergeable_checked_at).to be_present
    end
  end

  describe "skips" do
    # Force the job (and its auto-created initial Run) into existence
    # BEFORE each assertion's `expect { ... }.to change(Run, :count)`
    # block — otherwise lazy let-creation makes the initial Run look
    # like it was created by perform_now.
    before { job }

    it "skips when the PR has already merged" do
      stub_pr(pr_resource(merged: true, state: "closed"))
      expect { described_class.perform_now(job.id) }.not_to change(Run, :count)
    end

    it "skips when the PR was closed without merging" do
      stub_pr(pr_resource(state: "closed"))
      expect { described_class.perform_now(job.id) }.not_to change(Run, :count)
    end

    it "skips when GitHub hasn't computed mergeability yet (mergeable: nil)" do
      stub_pr(pr_resource(mergeable: nil))
      expect { described_class.perform_now(job.id) }.not_to change(Run, :count)
    end

    it "skips when the PR is mergeable" do
      stub_pr(pr_resource(mergeable: true))
      expect { described_class.perform_now(job.id) }.not_to change(Run, :count)
    end

    it "skips when the head is in a fork (different repo from base)" do
      stub_pr(pr_resource(mergeable: false, head_repo: "fork/widgets", base_repo: "acme/widgets"))
      expect { described_class.perform_now(job.id) }.not_to change(Run, :count)
    end

    it "skips when a rebase Workflow is already active on this Job" do
      stub_pr(pr_resource(mergeable: false))
      Workflow.create!(job: job, trigger_kind: "rebase", state: "queued")
      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
    end

    def rebase_workflow(state)
      Workflow.create!(job: job, trigger_kind: "rebase", state: state)
    end

    context "rebase attempt cap (consecutive failures since last success)" do
      it "does not block a Job whose rebase workflows all succeeded" do
        stub_pr(pr_resource(mergeable: false))
        5.times { rebase_workflow("succeeded") }
        expect {
          described_class.perform_now(job.id)
        }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
      end

      it "does not block when only 1 failure follows prior successes" do
        stub_pr(pr_resource(mergeable: false))
        4.times { rebase_workflow("succeeded") }
        rebase_workflow("failed")
        expect {
          described_class.perform_now(job.id)
        }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
      end

      it "blocks when all rebase workflows failed consecutively" do
        stub_pr(pr_resource(mergeable: false))
        5.times { rebase_workflow("failed") }
        expect {
          described_class.perform_now(job.id)
        }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
      end

      it "blocks when 5 consecutive failures follow prior successes" do
        stub_pr(pr_resource(mergeable: false))
        4.times { rebase_workflow("succeeded") }
        5.times { rebase_workflow("failed") }
        expect {
          described_class.perform_now(job.id)
        }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
      end
    end

    it "uses external_pr_number when pr_number is nil" do
      job.update!(pr_number: nil, external_pr_number: 99)
      pr = pr_resource(mergeable: false)
      expect_any_instance_of(GithubClient).to receive(:pull_request)
        .with("acme/widgets", 99, hash_including(bypass_cache: false))
        .and_return(pr)

      expect {
        described_class.perform_now(job.id)
      }.to change { job.runs.where(trigger_kind: "rebase").count }.by(1)
    end

    it "passes bypass_cache through when called with bypass_cache: true" do
      pr = pr_resource(mergeable: false)
      expect_any_instance_of(GithubClient).to receive(:pull_request)
        .with("acme/widgets", job.pr_number, hash_including(bypass_cache: true))
        .and_return(pr)

      described_class.perform_now(job.id, bypass_cache: true)
    end

    it "skips silently when neither pr_number nor external_pr_number is set" do
      job.update!(pr_number: nil, external_pr_number: nil)
      expect_any_instance_of(GithubClient).not_to receive(:pull_request)
      expect { described_class.perform_now(job.id) }.not_to change(Run, :count)
    end
  end
end
