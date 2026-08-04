require "rails_helper"

RSpec.describe LandingQueueProcessor, "merge-train integration" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
  let(:epic) { Factories.epic(user: user, repository: repository, state: "in_progress") }

  def approved_child(issue_number)
    Factories.job_record(
      user: user, repository: repository, epic: epic,
      issue_number: issue_number, state: "approved",
      pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
    )
  end

  def approved_reconciliation_job
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      kind: "direct",
      issue_number: nil,
      issue_title: "Reconciliation: Test Epic",
      state: "approved",
      pr_number: 2166,
      branch_name: "syrus/direct-reconciliation",
      pr_checks_state: "passing",
      github_mergeable_state: "clean",
      github_mergeable: true,
      local_mergeable: true,
      local_mergeable_state: "clean",
      approved_at: 1.minute.ago
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

    it "does not treat the historical reconciliation Job itself as a merge-train child" do
      AppSetting.current.update!(merge_train_enabled: true)
      reconciliation = approved_reconciliation_job
      epic.update!(reconciliation_job_id: reconciliation.id)

      entry = described_class.entries(Job.where(id: reconciliation.id)).first

      expect(entry.blocked_reason).to be_nil
      expect(entry.landing_unit_key).to eq("job:#{reconciliation.id}")
    end

    it "keeps non-reconciliation siblings blocked on the open reconciliation Job" do
      AppSetting.current.update!(merge_train_enabled: true)
      reconciliation = approved_reconciliation_job
      epic.update!(reconciliation_job_id: reconciliation.id)
      child = approved_child(1)

      entry = described_class.entries(Job.where(id: child.id)).first

      expect(entry.blocked_reason).to eq({ key: "epic_reconciliation_pending" })
      expect(entry.landing_unit_key).to eq("epic:#{epic.id}")
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

    it "does not dispatch a lower-priority train ahead of a higher-priority loose Job" do
      AppSetting.current.update!(merge_train_enabled: true)
      approved_child(1).update!(approved_at: 10.minutes.ago, priority: "low")
      loose = Factories.job_record(
        user: user, repository: repository,
        issue_number: 9, state: "implemented",
        pr_number: 509, branch_name: "syrus/issue-9"
      )
      loose.approve!(via: "operator")
      loose.update!(approved_at: 1.minute.ago, priority: "urgent")
      allow(MergeTrainDispatcher).to receive(:try_dispatch!).and_return(Object.new)

      workflow = described_class.call

      expect(workflow.job).to eq(loose)
      expect(loose.reload).to be_landing
      expect(MergeTrainDispatcher).not_to have_received(:try_dispatch!)
    end

    it "keeps a priority-boosted Epic train as one landing unit" do
      AppSetting.current.update!(merge_train_enabled: true)
      low_child = approved_child(1).tap { |job| job.update!(approved_at: 10.minutes.ago, priority: "low") }
      urgent_child = approved_child(2).tap { |job| job.update!(approved_at: 1.minute.ago, priority: "urgent") }
      high_loose = Factories.job_record(
        user: user, repository: repository,
        issue_number: 9, state: "approved",
        pr_number: 509, branch_name: "syrus/issue-9",
        approved_at: 5.minutes.ago, priority: "high"
      )

      entries = described_class.entries(Job.where(id: [ low_child.id, urgent_child.id, high_loose.id ]))

      expect(entries.map(&:job_id)).to eq([ urgent_child.id, low_child.id, high_loose.id ])
      expect(entries.first(2).map(&:landing_unit_key).uniq).to eq([ "epic:#{epic.id}" ])
    end

    it "does not dispatch a train while a member has an unmerged external blocker" do
      AppSetting.current.update!(merge_train_enabled: true)
      blocker = Factories.job_record(
        user: user, repository: repository,
        issue_number: 9, state: "implemented",
        pr_number: 509, branch_name: "syrus/issue-9"
      )
      child = approved_child(1)
      JobDependency.create!(job: child, depends_on_job: blocker, source: "manual")
      allow(MergeTrainDispatcher).to receive(:try_dispatch!).and_return(Object.new)

      expect(described_class.call).to be_nil
      expect(MergeTrainDispatcher).not_to have_received(:try_dispatch!)
    end

    it "routes try_land! for an Epic child to the train dispatcher" do
      AppSetting.current.update!(merge_train_enabled: true)
      child = approved_child(1)
      allow(MergeTrainDispatcher).to receive(:try_dispatch!).and_return(nil)

      described_class.new.try_land!(child)

      expect(MergeTrainDispatcher).to have_received(:try_dispatch!).with(epic)
    end

    it "lands the reconciliation Job through the per-Job path while merge trains are enabled" do
      AppSetting.current.update!(merge_train_enabled: true)
      reconciliation = approved_reconciliation_job
      epic.update!(reconciliation_job_id: reconciliation.id)
      allow(MergeTrainDispatcher).to receive(:try_dispatch!)

      processor = described_class.new

      workflow = processor.try_land!(reconciliation)

      expect(workflow).to be_present
      expect(workflow).to have_attributes(job: reconciliation, trigger_kind: "auto_merge")
      expect(reconciliation.reload).to be_landing
      expect(MergeTrainDispatcher).not_to have_received(:try_dispatch!)
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
