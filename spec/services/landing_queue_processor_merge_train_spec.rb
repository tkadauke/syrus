require "rails_helper"

RSpec.describe LandingQueueProcessor, "merge-train integration" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def approved_child(issue_number)
    Factories.job_record(
      user: user, repository: repository, epic: epic,
      issue_number: issue_number, state: "approved",
      pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
    )
  end

  describe "blockage" do
    before { epic.update_columns(state: "in_progress") }

    it "keeps Epic children off the per-Job path when the flag is on" do
      AppSetting.current.update!(merge_train_enabled: true)
      child = approved_child(1)

      entry = described_class.entries(Job.where(id: child.id)).first
      expect(entry.blocked_reason).to eq({ key: "waiting_epic_merge_train" })
    end

    it "surfaces the Epic release gate before the merge-train wait" do
      AppSetting.current.update!(merge_train_enabled: true)
      epic.update_columns(state: "backlog")
      child = approved_child(1)

      entry = described_class.entries(Job.where(id: child.id)).first
      expect(entry.blocked_reason).to eq({ key: "waiting_epic_release" })
    end

    it "does not block Epic children for the merge-train reason when the flag is off" do
      AppSetting.current.update!(merge_train_enabled: false)
      child = approved_child(1)

      entry = described_class.entries(Job.where(id: child.id)).first
      expect(entry.blocked_reason).not_to eq({ key: "waiting_epic_merge_train" })
    end
  end

  describe "#call" do
    it "dispatches a merge-train for a ready Epic instead of per-Job auto-merges" do
      AppSetting.current.update!(merge_train_enabled: true)
      approved_child(1)
      approved_child(2)
      allow(MergeTrainDispatcher).to receive(:try_dispatch!).and_return(Object.new)

      described_class.call

      expect(MergeTrainDispatcher).to have_received(:try_dispatch!).with(epic)
      expect(Workflow.where(trigger_kind: "auto_merge").count).to eq(0)
    end

    it "routes try_land! for an Epic child to the train dispatcher" do
      AppSetting.current.update!(merge_train_enabled: true)
      child = approved_child(1)
      allow(MergeTrainDispatcher).to receive(:try_dispatch!).and_return(nil)

      described_class.new.try_land!(child)

      expect(MergeTrainDispatcher).to have_received(:try_dispatch!).with(epic)
    end
  end

  describe EpicLandingRetrier do
    it "re-approves implemented children and kicks the queue" do
      AppSetting.current.update!(merge_train_enabled: true)
      a = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1,
                              state: "implemented", pr_number: 501, branch_name: "syrus/issue-1")
      allow(LandingQueueProcessor).to receive(:try_land!)

      result = EpicLandingRetrier.call(epic, by_user: user)

      expect(a.reload.state).to eq("approved")
      expect(a.approved_via).to eq("operator")
      expect(result.map(&:id)).to eq([ a.id ])
      expect(LandingQueueProcessor).to have_received(:try_land!)
    end
  end
end
