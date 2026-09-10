require "rails_helper"

RSpec.describe LandingRetrier do
  describe ".rebuild_job_bundle! (bundle scope, formerly JobBundleRetrier)" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

    def bundle_job(issue_number:, state:)
      Factories.job_record(
        user: user, repository: repository, epic: nil,
        issue_number: issue_number, state: state,
        pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
      )
    end

    # Regression for the the relevant change incident: once MergeTrainFailureHandler has
    # already self-healed a member whose commits genuinely landed before the
    # train crashed (closing it pr_merged instead of reverting it, see
    # MergeTrainFailureHandler#complete_landing!), a subsequent rebuild must
    # not reset that Job back to :implemented/:approved -- it is done, and
    # its branch is likely already deleted.
    it "does not reset a Job that MergeTrainFailureHandler already closed as landed" do
      healed = bundle_job(issue_number: 1, state: "closed")
      healed.update!(closure_reason: "pr_merged", landed_sha: "trainsha789")
      genuinely_failed = bundle_job(issue_number: 2, state: "failed")
      train = MergeTrain.create!(repository: repository, base_branch: "master", priority: "medium",
                                  integration_branch: "syrus/job-bundle-x", state: "failed", finished_at: Time.current)
      MergeTrainMember.create!(merge_train: train, job: healed, position: 0, state: "merged")
      MergeTrainMember.create!(merge_train: train, job: genuinely_failed, position: 1, state: "failed")
      allow(JobBundleDispatcher).to receive(:try_dispatch!).and_return(nil)

      result = described_class.rebuild_job_bundle!(repository, source_train: train)

      expect(result.recovered_jobs).to eq([ genuinely_failed ])
      expect(genuinely_failed.reload.state).to eq("approved")
      expect(healed.reload).to be_closed
      expect(healed.closure_reason).to eq("pr_merged")
      expect(healed.landed_sha).to eq("trainsha789")
    end
  end

  describe ".for_epic (epic scope, formerly EpicLandingRetrier)" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
    let(:epic) { Factories.epic(user: user, repository: repository, state: "in_progress") }

    it "re-approves implemented children and kicks the queue" do
      AppSetting.current.update!(merge_train_enabled: true)
      a = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1,
                              state: "implemented", pr_number: 501, branch_name: "syrus/issue-1")
      allow(LandingQueueProcessor).to receive(:try_land!)

      result = described_class.for_epic(epic, by_user: user)

      expect(a.reload.state).to eq("approved")
      expect(a.approved_via).to eq("operator")
      expect(result.map(&:id)).to eq([ a.id ])
      expect(LandingQueueProcessor).to have_received(:try_land!)
    end
  end
end
