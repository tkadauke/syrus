require "rails_helper"

RSpec.describe WorkEngine::RuntimeOwnership do
  def attach_epic_unit(epic, workflow, member_jobs:, state: "running")
    intent = WorkIntent.create!(
      kind: "merge_train",
      state: "requested",
      repository: epic.repository,
      scope_type: "epic",
      scope_id: epic.id,
      actor: epic.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: "merge_train",
      state: state,
      repository: epic.repository,
      scope_type: "epic",
      scope_id: epic.id,
      workflow: workflow
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end

  def attach_landing_unit(job, workflow: nil, kind: "auto_merge", state: "running")
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      actor: job.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow
    )
    unit.work_unit_members.create!(job: job, role: "primary")
    unit
  end

  it "uses WorkUnit epic ownership" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "succeeded")
    attach_epic_unit(epic, workflow, member_jobs: [ first, second ])

    expect(described_class.active_epic_wide_workflow_for_job?(second)).to be true
  end

  it "ignores legacy active epic-wide workflows without WorkUnit ownership" do
    epic = Factories.epic
    job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    Workflow.create!(job: job, trigger_kind: "merge_train", state: "running")

    expect(described_class.active_epic_wide_workflow_for_job?(job)).to be false
  end

  it "does not treat non-landing active workflows as legacy landing ownership" do
    job = Factories.job_record
    Workflow.create!(job: job, trigger_kind: "initial", state: "running")

    expect(described_class.active_landing_work_for_job?(job)).to be false
  end

  it "uses WorkUnit landing ownership" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "succeeded")
    attach_landing_unit(job, workflow: workflow, state: "blocked")

    expect(described_class.active_landing_work_for_job?(job)).to be true
  end

  it "ignores non-landing work units when checking landing ownership" do
    job = Factories.job_record
    attach_landing_unit(job, kind: "initial", state: "running")

    expect(described_class.active_landing_work_for_job?(job)).to be false
  end

  # Regression: between a preserved train's failure and its relaunch there is
  # no active WorkUnit. The reconciler treated the anchor Job as orphaned and
  # deferred it, the relaunch was refused as "already approved", and teardown
  # then failed every other member out of landing.
  describe ".active_landing_work_for_job? with a preserved merge train" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    def preserved_train_for(job, attempt_state: :pending, train_state: "landing", scheduled_at: 30.seconds.from_now)
      train = MergeTrain.create!(repository: repository, base_branch: "main", state: train_state, priority: "medium")
      MergeTrainMember.create!(merge_train: train, job: job, position: 0)
      workflow = Workflow.create!(job: job, trigger_kind: "merge_train", state: "failed", artifacts: { "merge_train_id" => train.id })
      AutoRetryAttempt.create!(
        job: job, workflow: workflow, agent_provider: "claude", failure_classification: "landing_validation_unproven",
        retry_kind: AutoRetryAttempt::PRESERVED_MERGE_TRAIN_RETRY_KIND, attempt_number: 1, scheduled_at: scheduled_at,
        performed_at: attempt_state == :performed ? Time.current : nil
      )
      train
    end

    it "counts a member of a train awaiting its preserved relaunch as owned" do
      job = Factories.job_record(user: user, repository: repository, state: "landing", pr_number: 11, branch_name: "syrus/a")
      preserved_train_for(job)

      expect(described_class.active_landing_work_for_job?(job)).to be(true)
    end

    it "lets go once the relaunch has been performed or the train is over" do
      performed = Factories.job_record(user: user, repository: repository, state: "landing", pr_number: 12, branch_name: "syrus/b", issue_number: 12)
      preserved_train_for(performed, attempt_state: :performed)
      finished = Factories.job_record(user: user, repository: repository, state: "landing", pr_number: 13, branch_name: "syrus/c", issue_number: 13)
      preserved_train_for(finished, train_state: "failed")

      expect(described_class.active_landing_work_for_job?(performed)).to be(false)
      expect(described_class.active_landing_work_for_job?(finished)).to be(false)
    end

    # The relaunch is scheduled 30 seconds out. An attempt still pending long
    # after that never ran (its AutoRetryJob raised and failed, for one), and
    # counting it as landing work forever hid the stuck train from the
    # reconciler, which before this window existed would have deferred it.
    it "stops counting a relaunch that is long overdue" do
      job = Factories.job_record(user: user, repository: repository, state: "landing", pr_number: 14, branch_name: "syrus/d", issue_number: 14)
      preserved_train_for(job, scheduled_at: 2.hours.ago)

      expect(described_class.active_landing_work_for_job?(job)).to be(false)
    end

    it "still counts a relaunch that is due but within the grace" do
      job = Factories.job_record(user: user, repository: repository, state: "landing", pr_number: 15, branch_name: "syrus/e", issue_number: 15)
      preserved_train_for(job, scheduled_at: 1.minute.ago)

      expect(described_class.active_landing_work_for_job?(job)).to be(true)
    end
  end
end
