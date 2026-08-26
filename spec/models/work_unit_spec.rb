require "rails_helper"

RSpec.describe WorkUnit do
  def intent
    @intent ||= WorkIntent.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123)
  end

  it "defaults blocked_details and exposes active/terminal predicates" do
    unit = described_class.create!(work_intent: intent, kind: "initial", state: "blocked", scope_type: "job", scope_id: 123,
                                   blocked_reason: "auto_retry_backoff")

    expect(unit.blocked_details).to eq({})
    expect(unit).to be_active
    expect(unit).not_to be_terminal
  end

  it "validates state and blocked reason vocabularies" do
    unit = described_class.new(work_intent: intent, kind: "initial", state: "bogus", scope_type: "job",
                               blocked_reason: "mystery")

    expect(unit).not_to be_valid
    expect(unit.errors[:state]).to be_present
    expect(unit.errors[:blocked_reason]).to be_present
  end

  it "accepts typed scheduler block reasons" do
    expected_reasons = %w[
      admission_control
      provider_availability
      manual_pause
      main_branch_health
      dependency_failed
      stack_dependencies_not_ready
      stack_fan_in_base_unavailable
      job_not_ready_for_execution
      urgent_job_active
      epic_wide_workflow_active
      resource_safety
      ci_repair_safety
      active_work_lock
      auto_retry_backoff
      preempted
    ]

    expect(described_class::BLOCKED_REASONS).to contain_exactly(*expected_reasons)

    expected_reasons.each do |reason|
      unit = described_class.new(work_intent: intent, kind: "initial", state: "blocked", scope_type: "job", scope_id: 123,
                                 blocked_reason: reason)

      expect(unit).to be_valid, "expected #{reason.inspect} to be a valid WorkUnit blocked reason"
    end
  end

  it "splits dependency-wait reasons out of the pause-worthy reasons" do
    expect(described_class::DEPENDENCY_BLOCKED_REASONS).to contain_exactly(
      "dependency_failed",
      "stack_dependencies_not_ready",
      "stack_fan_in_base_unavailable",
      "job_not_ready_for_execution"
    )

    expect(described_class::PAUSE_BLOCKED_REASONS).to match_array(
      described_class::BLOCKED_REASONS - described_class::DEPENDENCY_BLOCKED_REASONS
    )
    expect(described_class::PAUSE_BLOCKED_REASONS & described_class::DEPENDENCY_BLOCKED_REASONS).to be_empty
  end

  it "resolves its work definition from kind" do
    unit = described_class.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123)

    expect(unit.definition).to be_a(WorkDefinitions::Initial)
  end

  it "can point at a child validation unit without changing the parent attempt" do
    parent = described_class.create!(work_intent: intent, kind: "auto_merge", state: "running", scope_type: "job", scope_id: 123)
    child = described_class.create!(work_intent: intent, kind: "landing_validation", state: "queued", scope_type: "job",
                                    scope_id: 123, parent_work_unit: parent)

    expect(parent.child_work_units).to contain_exactly(child)
  end

  it "blocks and unblocks with typed runtime reason details" do
    user = Factories.user
    unit = described_class.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123)

    unit.block!(
      reason: "admission_control",
      blocked_until: 5.minutes.from_now,
      details: { "available_slots" => 0 },
      user: user
    )

    expect(unit).to have_attributes(state: "blocked", blocked_reason: "admission_control", blocked_by_user: user)
    expect(unit.blocked_details).to include("available_slots" => 0)

    unit.unblock!

    expect(unit).to have_attributes(state: "queued", blocked_reason: nil, blocked_until: nil, blocked_by_user: nil)
    expect(unit.blocked_details).to eq({})
  end

  it "marks running and terminal lifecycle states" do
    unit = described_class.create!(work_intent: intent, kind: "initial", state: "blocked", scope_type: "job", scope_id: 123,
                                   blocked_reason: "manual_pause", blocked_details: { "operator" => true })
    lock = unit.work_unit_locks.create!(lock_key: "job:123")

    unit.mark_running!
    expect(unit).to have_attributes(state: "running", blocked_reason: nil, finished_at: nil)
    expect(unit.started_at).to be_present

    unit.mark_terminal!("succeeded")
    expect(unit).to have_attributes(state: "succeeded")
    expect(unit.finished_at).to be_present
    expect(lock.reload).not_to be_active
  end

  it "rejects non-terminal states through mark_terminal!" do
    unit = described_class.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123)

    expect {
      unit.mark_terminal!("running")
    }.to raise_error(ArgumentError, /terminal/)
  end

  it "records manual pause intent separately from blocked state" do
    unit = described_class.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123)

    unit.request_pause!
    expect(unit.reload.pause_requested).to be true

    unit.clear_pause!
    expect(unit.reload.pause_requested).to be false
  end
end
