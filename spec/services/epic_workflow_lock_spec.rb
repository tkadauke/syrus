require "rails_helper"

RSpec.describe EpicWorkflowLock do
  def attach_epic_unit(epic, workflow, member_jobs:, kind: "merge_train", scope_type: "epic", scope_id: epic.id)
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: epic.repository,
      scope_type: scope_type,
      scope_id: scope_id,
      actor: epic.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: "running",
      repository: epic.repository,
      scope_type: scope_type,
      scope_id: scope_id,
      workflow: workflow
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end

  it "ignores legacy Epic-wide workflows" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
    candidate = Workflow.create!(job: second, trigger_kind: "initial", state: "queued")

    expect(described_class.blocking_workflow_for(candidate)).to be_nil
  end

  it "uses active Epic WorkUnit ownership" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    blocker = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
    attach_epic_unit(epic, blocker, member_jobs: [ first, second ])
    candidate = Workflow.create!(job: second, trigger_kind: "initial", state: "queued")

    expect(described_class.blocking_workflow_for(candidate)).to eq(blocker)
  end

  it "uses WorkUnit membership when Epic-wide work is not directly epic-scoped" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    blocker = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
    attach_epic_unit(epic, blocker, member_jobs: [ first, second ], scope_type: "job", scope_id: first.id)
    candidate = Workflow.create!(job: second, trigger_kind: "initial", state: "queued")

    expect(described_class.blocking_workflow_for(candidate)).to eq(blocker)
  end

  it "ignores active Epic WorkUnits whose workflow already finished" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    blocker = Workflow.create!(job: first, trigger_kind: "merge_train", state: "succeeded")
    attach_epic_unit(epic, blocker, member_jobs: [ first, second ])
    candidate = Workflow.create!(job: second, trigger_kind: "initial", state: "queued")

    expect(described_class.blocking_workflow_for(candidate)).to be_nil
  end

  it "detects conflicts from active WorkUnits instead of raw active Workflows" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    legacy = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
    conflict = Workflow.create!(job: second, trigger_kind: "initial", state: "running")
    conflict_unit = attach_epic_unit(epic, conflict, member_jobs: [ second ], kind: "initial", scope_type: "job", scope_id: second.id)

    expect(described_class.conflicting_active_units([ conflict_unit ])).to be_empty

    keeper = attach_epic_unit(epic, legacy, member_jobs: [ first, second ])
    conflicts = described_class.conflicting_active_units([ keeper, conflict_unit ])

    expect(conflicts).to contain_exactly(
      include(
        workflow: conflict,
        keeper: legacy,
        work_unit: conflict_unit,
        keeper_work_unit: keeper,
        reason: "an Epic-wide workflow is active"
      )
    )
  end

  # Members wait for Epic-wide work and Epic-wide work waits for running
  # members (StepDispatcher's two Epic start blocks). The reconciler cancelled
  # both kinds of waiter anyway, and the cancelled members were relaunched and
  # cancelled again (EpicWide.recon_before_cancels_queued_member /
  # recon_before_preempts_running_member).
  describe "conflicts agree with the Epic start waits" do
    let(:epic) { Factories.epic }
    let(:first) { Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1) }
    let(:second) { Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2) }

    def member_unit(state)
      workflow = Workflow.create!(job: second, trigger_kind: "initial", state: state)
      [ workflow, attach_epic_unit(epic, workflow, member_jobs: [ second ], kind: "initial", scope_type: "job", scope_id: second.id) ]
    end

    def epic_wide_unit(state)
      workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: state)
      [ workflow, attach_epic_unit(epic, workflow, member_jobs: [ first, second ]) ]
    end

    it "leaves a member queued behind a running Epic-wide workflow alone" do
      _, keeper = epic_wide_unit("running")
      _, member = member_unit("queued")

      expect(described_class.conflicting_active_units([ keeper, member ])).to be_empty
    end

    it "leaves the running member a queued Epic-wide workflow is waiting for alone" do
      _, keeper = epic_wide_unit("queued")
      _, member = member_unit("running")

      expect(described_class.conflicting_active_units([ keeper, member ])).to be_empty
    end

    it "still reports a running member under a running Epic-wide workflow" do
      _, keeper = epic_wide_unit("running")
      workflow, member = member_unit("running")

      expect(described_class.conflicting_active_units([ keeper, member ]))
        .to contain_exactly(include(workflow: workflow, reason: "an Epic-wide workflow is active"))
    end

    it "still reports a second active Epic-wide workflow, queued or not" do
      _, keeper = epic_wide_unit("running")
      second_wide = Workflow.create!(job: second, trigger_kind: "stack_rebase", state: "queued")
      second_unit = attach_epic_unit(epic, second_wide, member_jobs: [ first, second ], kind: "stack_rebase")

      expect(described_class.conflicting_active_units([ keeper, second_unit ]))
        .to contain_exactly(include(workflow: second_wide, reason: "another Epic-wide workflow is already active"))
    end
  end
end
